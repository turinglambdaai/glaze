#lang racket/base

(require json
         net/url
         racket/file
         racket/list
         racket/runtime-path
         racket/string
         rackunit
         web-server/http/request-structs
         web-server/http/response-structs
         glaze/api
         glaze/bridge
         glaze/capability
         glaze/private/bridge-dispatch
         glaze/types
         (rename-in glaze/native-transport [current-glaze-error-reporter native-error-reporter])
         (rename-in glaze/server [current-glaze-error-reporter http-error-reporter]))

(define-runtime-path server-source "../glaze/server.rkt")
(define-runtime-path native-source "../glaze/native-transport.rkt")

(define raw-response
  (response/full 202 #"Accepted" (current-seconds) #"text/plain" '() (list #"raw")))

(define routes
  (list
   (GET "api/ping" (lambda (_request) (hasheq 'pong #t)))
   (POST "api/echo"
         (lambda (request) (hash-ref (request-json-body request) 'name))
         #:body-types (list (cons "name" GString))
         #:returns GString)
   (GET "api/boom" (lambda (_request) (error 'boom "SECRET-DISPATCH-DETAIL")))
   (GET "api/slow"
        (lambda (_request)
          (sleep 0.05)
          "done")
        #:returns GString)
   (GET "api/raw" (lambda (_request) raw-response))
   (GET "api/protected" (lambda (_request) "allowed") #:permission 'files:read #:returns GString)))

(define (dispatch body [authority #f] [streams #f])
  (dispatch-bridge body routes authority (make-request-table) route->js-name streams))

(define (error-code response)
  (hash-ref (hash-ref response 'error) 'code))

(test-case "public carriers re-export one shared error reporter parameter"
  (check-eq? current-glaze-error-reporter native-error-reporter)
  (check-eq? current-glaze-error-reporter http-error-reporter))

(test-case "both carriers depend directly on the shared dispatch owner"
  (check-false (regexp-match? #px"\"native-transport[.]rkt\"" (file->string server-source)))
  (check-true (regexp-match? #px"\"private/bridge-dispatch[.]rkt\"" (file->string server-source)))
  (check-true (regexp-match? #px"\"private/bridge-dispatch[.]rkt\"" (file->string native-source))))

(test-case "synthetic requests preserve method, URI, and body"
  (define request (synthetic-request 'POST "api/echo" #"{\"name\":\"Ada\"}"))
  (check-equal? (request-method request) #"POST")
  (check-equal? (url->string (request-uri request)) "glaze://app/api/echo")
  (check-equal? (request-post-data/raw request) #"{\"name\":\"Ada\"}"))

(test-case "invoke dispatch shares JSON args and typed validation"
  (define ok
    (dispatch
     (hasheq 'glz 1 'id "echo-ok" 'method "POST" 'path "api/echo" 'args (hasheq 'name "Ada"))))
  (check-true (hash-ref ok 'ok))
  (check-equal? (hash-ref ok 'value) "Ada")
  (define invalid
    (dispatch
     (hasheq 'glz 1 'id "echo-invalid" 'method "POST" 'path "api/echo" 'args (hasheq 'name 42))))
  (check-equal? (error-code invalid) "invalid-args"))

(test-case "dispatch preserves capability and response pass-through contracts"
  (define denied
    (dispatch (hasheq 'glz 1 'id "denied" 'path "api/protected") (make-capability "reader" '())))
  (check-equal? (error-code denied) "capability-denied")
  (define allowed
    (dispatch (hasheq 'glz 1 'id "allowed" 'path "api/protected")
              (make-capability "reader" '(files:read))))
  (check-equal? (hash-ref allowed 'value) "allowed")
  (check-eq? (dispatch (hasheq 'glz 1 'id "raw" 'path "api/raw")) raw-response))

(test-case "handler failures are reported once without leaking details"
  (define reports (box '()))
  (define result
    (parameterize ([current-glaze-error-reporter
                    (lambda (exception uri)
                      (set-box! reports (cons (list exception uri) (unbox reports))))])
      (dispatch (hasheq 'glz 1 'id "boom" 'path "api/boom"))))
  (check-equal? (error-code result) "internal")
  (check-false (string-contains? (format "~a" result) "SECRET-DISPATCH-DETAIL"))
  (check-equal? (length (unbox reports)) 1)
  (check-equal? (second (car (unbox reports))) "glz1:api/boom"))

(test-case "timeout and cancel retain GLZ1 terminal semantics"
  (define timed-out (dispatch (hasheq 'glz 1 'id "slow" 'path "api/slow" 'timeout_ms 1)))
  (check-equal? (hash-ref timed-out 'outcome) "timed-out")
  (check-equal? (error-code timed-out) "timed-out")
  (define-values (_input output) (make-pipe))
  (define streams (make-hash (list (cons "stream-1" output))))
  (define cancelled (dispatch (hasheq 'glz 1 'op "cancel" 'id "stream-1") #f streams))
  (check-true (hash-ref cancelled 'ok))
  (check-true (port-closed? output)))

(test-case "hello and malformed messages use the same envelope vocabulary"
  (define hello (dispatch (hasheq 'glz 1 'op "hello" 'id "hello")))
  (check-true (hash-ref hello 'ok))
  (check-equal? (hash-ref (hash-ref hello 'value) 'glz) 1)
  (check-equal? (error-code (dispatch 42)) "bad-envelope"))
