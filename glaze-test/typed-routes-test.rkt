#lang racket/base

;; Typed command declarations (A1): declared keel types drive wire
;; validation on BOTH transports (GLZ1 invoke and plain fetch), the
;; /glaze/hello schema projection carries the real types, /glaze/api.d.ts
;; serves generated TypeScript declarations, and schema-compat reports
;; breaking evolutions.

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/string
         json
         net/http-client
         (only-in keel
                  app-schema-commands
                  make-app-schema
                  schema-command
                  schema-command-error-codes
                  schema-command-name
                  schema-command-parameters
                  schema-command-result
                  schema-parameter
                  String
                  Value)
         glaze/api
         glaze/api-macros
         glaze/bridge
         glaze/native-transport
         glaze/schema-compat
         glaze/server
         glaze/types)

;; ---- declarations ----

(define Item (grecord 'Item "id" GInt64 "name" GString "tags" (glist GString)))
(define Kind (genum 'Kind 'basic 'advanced))

(define-api-routes typed-api
                   [(GET "api/items/:id" #:body-types (list (cons "verbose" GBool)) #:returns Item)
                    (item-get id)
                    (hasheq 'id (string->number id) 'name "widget" 'tags (list "a"))]
                   [(POST "api/items")
                    (item-create [item Item] [kind Kind] [note GString "none"])
                    (hasheq 'created (hash-ref item 'name))]
                   [(POST "api/items/echo" #:returns GInt64)
                    (item-echo [item Item])
                    ;; deliberately violates the declared result type
                    item]
                   [(GET "api/legacy") (legacy) (hasheq 'anything 'null)])

;; route schema metadata landed
(define get-route (first typed-api))
(check-not-false (route-schema get-route) "typed route carries a keel command")
(check-equal? (schema-command-name (route-schema get-route)) "api-items-id-get")
(check-false (route-schema (fourth typed-api)) "untyped route stays untyped")

;; ---- invoke-channel validation (shared by GLZ1 native + /glaze/invoke) ----

(define table (make-request-table))

(define ping-resp
  (dispatch-invoke (hasheq 'glz 1 'id "t1" 'path "api/items/7" 'args (hasheq 'verbose #t))
                   typed-api
                   #f
                   table))
(check-true (hash-ref ping-resp 'ok) "valid args pass the typed contract")
(check-equal? (hash-ref (hash-ref ping-resp 'value) 'id) 7 "handler ran with the captured param")

;; violating a declared body parameter -> typed invalid-args
(define bad-resp
  (dispatch-invoke (hasheq 'glz
                           1
                           'id
                           "t2"
                           'path
                           "api/items"
                           'method
                           "POST"
                           'args
                           (hasheq 'item (hasheq 'id "not-an-int" 'name "x" 'tags '()) 'kind "basic"))
                   typed-api
                   #f
                   table))
(check-false (hash-ref bad-resp 'ok) "schema-violating args fail")
(check-equal? (hash-ref (hash-ref bad-resp 'error) 'code)
              "invalid-args"
              "violation is a typed invalid-args error")

;; violating the enum -> invalid-args
(define bad-kind
  (dispatch-invoke (hasheq 'glz
                           1
                           'id
                           "t3"
                           'path
                           "api/items"
                           'method
                           "POST"
                           'args
                           (hasheq 'item (hasheq 'id 1 'name "x" 'tags '()) 'kind "ultra"))
                   typed-api
                   #f
                   table))
(check-equal? (hash-ref (hash-ref bad-kind 'error) 'code)
              "invalid-args"
              "enum violation is invalid-args")

;; a handler result violating its declared type -> internal (server bug)
(define bad-result
  (dispatch-invoke (hasheq 'glz
                           1
                           'id
                           "t4"
                           'path
                           "api/items/echo"
                           'method
                           "POST"
                           'args
                           (hasheq 'item (hasheq 'id 1 'name "x" 'tags '())))
                   typed-api
                   #f
                   table))
(check-equal? (hash-ref (hash-ref bad-result 'error) 'code)
              "internal"
              "result violation answers a typed internal error")
(check-false (string-contains? (format "~a" bad-result) "SECRET") "no details leak")

;; untyped route: anything goes
(define legacy-resp (dispatch-invoke (hasheq 'glz 1 'id "t5" 'path "api/legacy") typed-api #f table))
(check-true (hash-ref legacy-resp 'ok) "untyped route keeps permissive behavior")

;; ---- HTTP channel: api.js parity, api.d.ts, result validation ----

(define http-dir (make-temporary-file "glaze-typed-~a" 'directory))
(define port 18955)
(define-values (http-port stop)
  (start-server #:port port #:public-dir http-dir #:api typed-api #:api-token #f))

(define (get path)
  (define-values (st h in) (http-sendrecv "127.0.0.1" path #:port port #:ssl? #f))
  (define body (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 st) body))

(define (post path body-js)
  (define-values (st h in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:method #"POST"
                   #:headers (list "Content-Type: application/json")
                   #:data (string->bytes/utf-8 body-js)
                   #:port port
                   #:ssl? #f))
  (define body (port->bytes in))
  (close-input-port in)
  (bytes->jsexpr body))

;; fetch channel result validation: echo violates its declared GInt64 result
(define echo-resp (post "/api/items/echo" "{\"item\":{\"id\":1,\"name\":\"x\",\"tags\":[]}}"))
(check-equal? (and (hash? echo-resp) (hash-ref echo-resp 'error #f))
              "internal error"
              "fetch channel also validates handler results")

;; api.d.ts served over HTTP
(define-values (dts-status dts-body) (get "/glaze/api.d.ts"))
(define dts (bytes->string/utf-8 dts-body))
(check-true (string-contains? dts-status "200") "api.d.ts is served")
(check-true (string-contains? dts "export interface Item {") "Item interface generated")
(check-true (string-contains? dts "Kind") "Kind named type present")
(check-true (string-contains? dts "glaze.itemsId(args: { verbose: boolean }): Promise<Item>")
            "command signature generated with declared types")
(check-true (string-contains? dts ": Promise<Item>") "result type in the signature")
(check-false (string-contains? dts "legacy") "untyped route stays out of the declarations")

;; hello carries the real types
(define-values (hello-status hello-body) (get "/glaze/hello"))
(check-true (string-contains? hello-status "200") "hello is served")
;; the typed command appears in hello with a REAL result type (Item, not
;; the permissive Value fallback) and Item itself is collected as a record
(define hello-json (bytes->jsexpr hello-body))
(define typed-hello
  (ormap (lambda (c) (and (equal? (hash-ref c 'name) "itemsId") c))
         (hash-ref (hash-ref hello-json 'schema) 'commands)))
(check-not-false typed-hello "typed command appears in hello")
(check-false (equal? (hash-ref typed-hello 'result #f) "value")
             "typed command carries a real result type, not the Value fallback")

(stop)
(delete-directory/files http-dir)
