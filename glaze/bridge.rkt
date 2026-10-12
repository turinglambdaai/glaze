#lang racket/base

;; GLZ1 — Glaze's versioned bridge protocol.
;;
;; The HTTP/SSE transport stays (the WebView loads from it today), but the
;; page<->Racket conversation gets what ad-hoc JSON routes never had:
;;
;;   - a protocol version, negotiated through GET /glaze/hello, so a
;;     frontend and a backend that disagree fail loudly at connect time;
;;   - request envelopes with a client-chosen id: POST /glaze/invoke wraps
;;     any registered route, so errors are typed instead of "whatever the
;;     500 body says" and one response can always be correlated to its call;
;;   - a closed error taxonomy (code + message + optional data), never
;;     internal exception text;
;;   - cancellation: POST /glaze/cancel marks an in-flight request; handlers
;;     observe it through current-bridge-cancel-event, and invoke's
;;     timeout_ms abandons the waiter even when the handler cannot be
;;     interrupted;
;;   - event sequence numbers on the SSE stream (id: lines) so a consumer
;;     can detect that the backlog overflow dropped something.
;;
;; The envelope layer is transport-agnostic on purpose: when the native
;; message-handler transport lands (docs/architecture-1.0.md), these same
;; structures move to it unchanged. See also rivet#196 — the value shapes
;; are the working proposal for the shared Glaze/Rivet protocol core.

(require json
         racket/list
         racket/string
         (only-in keel app-error-code app-error-data app-error-message app-null make-app-error)
         (only-in keel
                  schema-command
                  schema-parameter
                  schema-record
                  Value
                  String
                  make-app-schema
                  app-schema->app-value)
         "api.rkt")

(provide glz1-version
         bridge-error-code?
         raise-bridge-error
         bridge-error
         bridge-error-code
         bridge-error-message
         bridge-error-data
         exn:fail:glaze:bridge?
         exn:fail:glaze:bridge-code
         exn:fail:glaze:bridge-data
         parse-invoke-envelope
         build-invoke-response
         outcome-for-code
         bridge-error-object
         build-hello
         make-request-table
         request-table-cancel!
         request-table-cancelled?
         request-table-retire!
         call-with-bridge-request
         current-bridge-request-slot
         bridge-cancel-event
         bridge-cancelled?)

;; ---- version ----

(define glz1-version 1)

;; ---- typed errors ----

;; Closed taxonomy. `data` carries structured, non-sensitive detail (e.g.
;; which envelope field was wrong); never exception text.
(struct bridge-error (code message data) #:transparent)

(define error-codes
  '(unsupported-version bad-envelope
                        unknown-command
                        method-not-allowed
                        invalid-args
                        token-required
                        capability-denied
                        timed-out
                        cancelled
                        internal))

(define (bridge-error-code? code)
  (and (symbol? code) (memq code error-codes) #t))

;; Raise inside an invoke handler to answer a typed bridge error.
(struct exn:fail:glaze:bridge exn:fail (code data) #:transparent)

(define (raise-bridge-error code [message #f] [data app-null])
  (unless (bridge-error-code? code)
    (raise-argument-error 'bridge-error "bridge-error-code?" code))
  (raise (exn:fail:glaze:bridge (or message (string-titlecase (symbol->string code)))
                                (current-continuation-marks)
                                code
                                data)))

;; ---- envelopes ----

;; POST /glaze/invoke body -> (values id path method args) or a typed error.
;;   {"glz":1, "id":"...", "path":"api/items/42",
;;    "method":"GET" (optional), "args":{...} (optional)}
(define (parse-invoke-envelope body)
  (define (bad what [data #f])
    (raise-bridge-error 'bad-envelope what data))
  (unless (hash-eq? body)
    (bad "envelope must be a JSON object"))
  (define version (hash-ref body 'glz #f))
  (unless (eq? version glz1-version)
    (raise-bridge-error 'unsupported-version
                        (format "envelope glz version ~a, server speaks ~a" version glz1-version)))
  (define id (hash-ref body 'id #f))
  (unless (and (string? id) (not (string=? id "")))
    (bad "id must be a non-empty string"))
  (define path (hash-ref body 'path #f))
  (unless (and (string? path) (not (string=? path "")))
    (bad "path must be a non-empty string"))
  (define method-sym
    (let ([m (hash-ref body 'method #f)])
      (cond
        [(not m) #f]
        [(and (string? m) (member (string-upcase m) '("GET" "POST" "PUT" "DELETE")))
         (string->symbol (string-upcase m))]
        [else (bad "method must be one of GET/POST/PUT/DELETE")])))
  (define args (hash-ref body 'args #f))
  (when (and args (not (hash? args)))
    (bad "args must be a JSON object"))
  (values id path method-sym (or args (hasheq))))

;; HTTP status per error code — the transport binding stays in the server;
;; the protocol only names the class.
;; Every terminal invoke response names its outcome with the keel request
;; vocabulary (succeeded / failed / cancelled / timed-out); the error object
;; itself is a keel-shaped structured error (kebab code, message, data).
(define (build-invoke-response id result)
  (hasheq 'glz glz1-version 'id id 'ok #t 'outcome "succeeded" 'value result))

(define (outcome-for-code code)
  (cond
    [(eq? code 'cancelled) "cancelled"]
    [(eq? code 'timed-out) "timed-out"]
    [else "failed"]))

;; Build the wire error object through keel's structured-error shape, so the
;; code is validated kebab-case and the shape stays portable. `data` stays a
;; jsexpr on the wire (glaze-side detail); keel's app-null stands in for "no
;; data".
(define (bridge-error-object code message data)
  ;; Construct the shared value rather than merely copying its JSON shape.
  ;; This validates the code, message, and recursively converted data against
  ;; Keel before the transport boundary serializes it.
  (define error-value
    (make-app-error (symbol->string code)
                    (or message (string-titlecase (symbol->string code)))
                    (jsexpr->app-value data)))
  (hasheq 'code
          (app-error-code error-value)
          'message
          (app-error-message error-value)
          'data
          (app-value->jsexpr (app-error-data error-value))))

;; GET /glaze/hello — what a frontend checks before its first invoke.
;; `name-fn` derives each route's portable command name (server.rkt passes
;; the generated-JS-name function). The manifest carries both the raw route
;; list and a keel app-schema rendering of the same surface, so a frontend
;; (or a tool) can consume the transport-neutral description.
(define invoke-error-codes
  (list "invalid-args" "capability-denied" "token-required" "timed-out" "cancelled" "internal"))

(define (build-hello routes [app-id #f] [name-fn #f])
  (define route-name
    (or name-fn
        (lambda (segments)
          (string-join (for/list ([seg (in-list segments)])
                         (if (param? seg)
                             (param-id seg)
                             seg))
                       "-"))))
  (define base-names
    (for/list ([r (in-list routes)])
      (route-name (route-segments r))))
  (define base-counts
    (for/fold ([counts (hash)]) ([base (in-list base-names)])
      (hash-update counts base add1 0)))
  ;; Keel command names are unique. Glaze deliberately supports one generated
  ;; JS function for GET/POST routes sharing a path, so qualify only overloaded
  ;; names with the method. If duplicate registrations still collide, append a
  ;; stable ordinal rather than making /glaze/hello fail at runtime.
  (define qualified-names
    (for/list ([r (in-list routes)]
               [base (in-list base-names)])
      (if (= (hash-ref base-counts base) 1)
          base
          (format "~a-~a" base (string-downcase (symbol->string (route-method r)))))))
  (define qualified-counts
    (for/fold ([counts (hash)]) ([name (in-list qualified-names)])
      (hash-update counts name add1 0)))
  (define seen (make-hash))
  (define command-names
    (for/list ([name (in-list qualified-names)])
      (define ordinal (add1 (hash-ref seen name 0)))
      (hash-set! seen name ordinal)
      (if (= (hash-ref qualified-counts name) 1)
          name
          (format "~a-~a" name ordinal))))
  (define schema
    (make-app-schema "glaze-routes"
                     1
                     #:commands (for/list ([r (in-list routes)]
                                           [command-name (in-list command-names)])
                                  (schema-command command-name
                                                  (for/list ([seg (in-list (route-segments r))]
                                                             #:when (param? seg))
                                                    (schema-parameter (param-id seg) String))
                                                  Value
                                                  invoke-error-codes))))
  (hasheq 'glz
          glz1-version
          'name
          "glaze"
          'app
          (or app-id #f)
          'routes
          (for/list ([r (in-list routes)])
            (hasheq 'method
                    (symbol->string (route-method r))
                    'path
                    (string-append "/"
                                   (string-join (for/list ([seg (in-list (route-segments r))])
                                                  (if (param? seg)
                                                      (string-append ":" (param-id seg))
                                                      seg))
                                                "/"))))
          'schema
          (app-value->jsexpr (app-schema->app-value schema))))

;; keel renders app-values with immutable STRING-key maps and its Null
;; sentinel; the wire speaks jsexpr, whose object keys are symbols. Convert
;; at the transport boundary — string keys become symbols, keel Null becomes
;; the JSON null symbol, errors unfold to their object shape.
(define (app-value->jsexpr v)
  (cond
    [(hash? v)
     (for/hasheq ([(key value) (in-hash v)])
       (values (string->symbol key) (app-value->jsexpr value)))]
    [(pair? v) (map app-value->jsexpr v)]
    [(null? v) v]
    [(eq? v app-null) 'null]
    [else v]))

(define (jsexpr->app-value v)
  (cond
    [(hash? v)
     (for/hash ([(key value) (in-hash v)])
       (values
        (cond
          [(symbol? key) (symbol->string key)]
          [(string? key) key]
          [else
           (raise-argument-error 'bridge-error-object "jsexpr object with symbol or string keys" v)])
        (jsexpr->app-value value)))]
    [(pair? v) (map jsexpr->app-value v)]
    [(null? v) v]
    [(eq? v 'null) app-null]
    [else v]))

;; ---- request table (cancellation) ----

;; id -> slot (a box holding the request's cancel semaphore). The semaphore
;; exists from install time; a cancel request POSTS it. Handlers sync on it
;; through bridge-cancel-event — before a cancel, the sync waits; after, it
;; returns immediately. The box indirection lets the transport install the
;; slot before the handler runs while the handler reads it at poll time.
(struct request-table (slots sema))

;; equal?-based hash: envelope ids are freshly parsed strings from
;; different connections, and eq? would treat two equal ids as different.
(define (make-request-table)
  (request-table (make-hash) (make-semaphore 1)))

(define (request-table-cancel! table id)
  (define slot
    (call-with-semaphore (request-table-sema table)
                         (lambda () (hash-ref (request-table-slots table) id #f))))
  (when slot
    (semaphore-post (unbox slot))))

(define (request-table-cancelled? table id)
  (define slot
    (call-with-semaphore (request-table-sema table)
                         (lambda () (hash-ref (request-table-slots table) id #f))))
  (and slot (sync/timeout 0 (unbox slot)) #t))

(define (request-table-retire! table id)
  (call-with-semaphore (request-table-sema table)
                       (lambda () (hash-remove! (request-table-slots table) id))))

(define current-bridge-request-slot (make-parameter #f))

;; The cancel event of the in-flight request, or #f when the handler is not
;; running under an invoke envelope. The event exists from install; syncing
;; on it blocks until POST /glaze/cancel fires, and (bridge-cancelled?)
;; polls without blocking.
(define (bridge-cancel-event)
  (define slot (current-bridge-request-slot))
  (and slot (unbox slot)))

(define (bridge-cancelled?)
  (define evt (bridge-cancel-event))
  (and evt (sync/timeout 0 evt) #t))

;; Install id in the table for the dynamic extent of body. The transport
;; binding (server.rkt) uses this around invoke handler dispatch.
(define (call-with-bridge-request table id body)
  (define cancel-sema (make-semaphore))
  (define slot (box cancel-sema))
  (call-with-semaphore (request-table-sema table)
                       (lambda () (hash-set! (request-table-slots table) id slot)))
  (dynamic-wind void
                (lambda ()
                  (parameterize ([current-bridge-request-slot slot])
                    (body)))
                (lambda () (request-table-retire! table id))))
