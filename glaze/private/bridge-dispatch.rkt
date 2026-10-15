#lang racket/base

;; Transport-neutral GLZ1 command dispatch shared by the native carrier and
;; the loopback HTTP development adapter. This owner contains no session,
;; stream-pump, socket, or platform-WebView lifecycle.

(require json
         racket/async-channel
         racket/list
         racket/promise
         racket/string
         net/url
         (only-in web-server/http/request-structs make-request)
         (only-in web-server/http/response-structs response?)
         (only-in keel
                  schema-command-parameters
                  schema-command-result
                  schema-parameter-name
                  schema-parameter-type)
         "../api.rkt"
         "../bridge.rkt"
         "../capability.rkt"
         "../types.rkt")

(provide dispatch-bridge
         dispatch-invoke
         synthetic-request
         current-glaze-error-reporter
         glz1-error-envelope)

;; Exception reporter for handler failures (the internal-error path). Lives
;; here — not in server.rkt — because native-transport worker threads report
;; through it too. Default logs to stderr; run-app parameterizes this to its
;; #:on-error callback.
(define current-glaze-error-reporter
  (make-parameter
   (lambda (exn uri)
     (fprintf (current-error-port) "[glaze] handler error on ~a: ~a\n" uri (exn-message exn)))))

;; ---- error envelope ----

;; The outcome field uses keel's request vocabulary; ok #f always names a
;; failed/cancelled/timed-out terminal, and the error object is keel-shaped.
(define (glz1-error-envelope id code message data)
  (hasheq 'glz
          glz1-version
          'id
          id
          'ok
          #f
          'outcome
          (outcome-for-code code)
          'error
          (bridge-error-object code message data)))

;; ---- dispatch core ----

;; Route lookup from envelope parts — the GLZ1 invoke names its target in
;; the envelope, not in a request URI.
(define (find-api-match-by-parts api-routes method segments)
  (for/or ([r (in-list api-routes)])
    (define captured (route-match r method segments))
    (and captured (list r captured))))

;; A minimal web-server request for handlers invoked through the native
;; transport. Handlers receive the envelope's args as their JSON body, like
;; the HTTP adapter's rewritten request.
(define (synthetic-request method path body-bytes)
  (make-request (string->bytes/latin-1 (symbol->string (or method 'GET)))
                (string->url (string-append "glaze://app/" path))
                '()
                (delay
                  '())
                body-bytes
                "127.0.0.1"
                0
                "native"))

;; POST /glaze/invoke (HTTP) and the message-handler invoke (native) share
;; this pipeline: envelope parse, route match, capability check, handler
;; invocation with a bounded async result path, and typed terminal outcomes.
;; The only transport difference is how the handler's request struct is
;; built; #:make-handler-request receives (method path body-bytes).
;;
;; Returns the response jsexpr, or a raw web-server response? when a handler
;; produces a full/streaming response — the HTTP adapter passes those to the
;; connection untouched; the native transport answers a typed error instead
;; (there is no wire to stream onto once the envelope is committed).
(define (dispatch-invoke body
                         routes
                         authority
                         table
                         #:make-handler-request [make-handler-request synthetic-request])
  (define-values (parse-result parse-error)
    (with-handlers ([exn:fail:glaze:bridge?
                     (lambda (e)
                       (values #f
                               (glz1-error-envelope #f
                                                    (exn:fail:glaze:bridge-code e)
                                                    (exn-message e)
                                                    (exn:fail:glaze:bridge-data e))))])
      (values (call-with-values (lambda () (parse-invoke-envelope body)) list) #f)))
  (cond
    [parse-error parse-error]
    [else
     (define id (list-ref parse-result 0))
     (define path (list-ref parse-result 1))
     (define method-sym (list-ref parse-result 2))
     (define args (list-ref parse-result 3))
     (define segments (filter (lambda (sg) (not (equal? sg ""))) (string-split path "/")))
     ;; An explicit envelope method must match exactly; without one, GET
     ;; wins, then the mutating methods in registration order.
     (define match
       (cond
         [method-sym (find-api-match-by-parts routes method-sym segments)]
         [else
          (or (find-api-match-by-parts routes 'GET segments)
              (for/or ([mth (in-list '(POST PUT DELETE))])
                (find-api-match-by-parts routes mth segments)))]))
     (define method-mismatch?
       (and method-sym
            (not match)
            (for/or ([mth (in-list '(GET POST PUT DELETE))])
              (find-api-match-by-parts routes mth segments))))
     (cond
       [(not match)
        (glz1-error-envelope id
                             (if method-mismatch? 'method-not-allowed 'unknown-command)
                             (format "no route matches ~a ~a" (or method-sym 'GET) path)
                             'null)]
       [(and authority
             (route-permission (first match))
             (not (capability-has-permission? authority (route-permission (first match)))))
        (glz1-error-envelope id 'capability-denied "capability denied API route" 'null)]
       [else
        (define route (first match))
        (define captured (second match))
        ;; Typed contract: declared body parameters are validated against
        ;; their keel types before the handler runs. dispatch-invoke is
        ;; callable standalone (direct dispatch callers), so violations
        ;; RETURN a typed envelope instead of raising.
        (define arg-violation
          (and (route-schema route)
               (for/or ([p (in-list (schema-command-parameters (route-schema route)))])
                 (define key (schema-parameter-name p))
                 (define-values (ok? why)
                   (validate-jsexpr (schema-parameter-type p)
                                    (hash-ref args (string->symbol key) 'null)))
                 (and (not ok?) (cons 'invalid-args (format "~a: ~a" key why))))))
        (cond
          [arg-violation (glz1-error-envelope id (car arg-violation) (cdr arg-violation) 'null)]
          [else
           (define timeout-secs
             (let ([ms (and (hash? body) (hash-ref body 'timeout_ms #f))])
               (and (exact-positive-integer? ms) (/ ms 1000.0))))
           (call-with-bridge-request
            table
            id
            (lambda ()
              ;; A timed-out caller stops receiving. A bounded async channel
              ;; lets the handler publish its eventual result and terminate
              ;; instead of leaking forever in a synchronous channel-put.
              (define result-ch (make-async-channel 1))
              (thread
               (lambda ()
                 (async-channel-put
                  result-ch
                  (with-handlers
                      ([exn:fail:glaze:bridge? (lambda (e)
                                                 (glz1-error-envelope id
                                                                      (exn:fail:glaze:bridge-code e)
                                                                      (exn-message e)
                                                                      (exn:fail:glaze:bridge-data
                                                                       e)))]
                       [exn:fail:glaze:bad-param?
                        (lambda (e) (glz1-error-envelope id 'invalid-args (exn-message e) 'null))]
                       [exn:fail? (lambda (e)
                                    ((current-glaze-error-reporter) e (string-append "glz1:" path))
                                    (glz1-error-envelope id 'internal "internal error" 'null))])
                    (define result
                      (parameterize ([current-capability-id (and authority (capability-id authority))]
                                     [current-capability-authorizer
                                      (and
                                       authority
                                       (lambda (permission resource)
                                         (capability-authorized? authority permission resource)))])
                        (apply (route-handler route)
                               (make-handler-request (or method-sym (route-method route))
                                                     path
                                                     (string->bytes/utf-8 (jsexpr->string args)))
                               captured)))
                    ;; Typed contract: a handler result violating its
                    ;; declared type is a server bug — full detail to the
                    ;; error reporter, typed internal error to the page.
                    (when (and (route-schema route) (not (response? result)))
                      (define-values (rok? rwhy)
                        (validate-jsexpr (schema-command-result (route-schema route)) result))
                      (unless rok?
                        ((current-glaze-error-reporter)
                         (exn:fail (format "result schema violation on ~a: ~a" path rwhy)
                                   (current-continuation-marks))
                         (string-append "glz1:" path))
                        (raise-bridge-error 'internal "internal error")))
                    ;; Streaming and full-response handlers bypass
                    ;; the envelope: the wire is already committed.
                    (if (response? result)
                        result
                        (build-invoke-response id result))))))
              (define maybe-result
                (if timeout-secs
                    (sync/timeout timeout-secs result-ch)
                    (sync result-ch)))
              (cond
                [(not maybe-result)
                 (glz1-error-envelope id
                                      'timed-out
                                      (format "handler exceeded ~ams" (hash-ref body 'timeout_ms))
                                      'null)]
                [else maybe-result])))])])]))

;; The op-routed entry both transports share. Native messages carry an "op"
;; field ("hello" / "cancel"); anything with a path is an invoke. HTTP keeps
;; its own GET /glaze/hello and POST /glaze/cancel endpoints (same wire
;; shapes), and routes its invoke bodies through here as well.
;; `streams` (the transport's active-stream registry, id -> output-port) is
;; optional so the HTTP-side callers and the tests keep the 5-arg shape.
;; Cancelling an id that is mid-stream closes its pipe: the writer ends,
;; EOF delivers the terminal frame, and the page's aborted promise was
;; already settled by the page-side cancel.
(define (dispatch-bridge body routes authority table name-fn [streams #f])
  (cond
    [(not (hash? body)) (glz1-error-envelope #f 'bad-envelope "message must be a JSON object" 'null)]
    [(equal? (hash-ref body 'op #f) "hello")
     (define id (hash-ref body 'id #f))
     (if (string? id)
         (build-invoke-response id (build-hello routes #f name-fn))
         (glz1-error-envelope #f 'bad-envelope "hello needs a non-empty id" 'null))]
    [(equal? (hash-ref body 'op #f) "cancel")
     (define id (hash-ref body 'id #f))
     (if (and (eq? (hash-ref body 'glz #f) glz1-version) (string? id) (not (string=? id "")))
         (begin
           (when (and streams (hash? streams))
             (define pout (hash-ref streams id #f))
             (when (output-port? pout)
               (close-output-port pout)))
           (request-table-cancel! table id)
           (hasheq 'glz glz1-version 'id id 'ok #t 'value "cancel-signalled"))
         (glz1-error-envelope #f 'bad-envelope "cancel needs {glz:1, id}" 'null))]
    [else (dispatch-invoke body routes authority table)]))
