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
                        timeout
                        cancelled
                        internal))

(define (bridge-error-code? code)
  (and (symbol? code) (memq code error-codes) #t))

;; Raise inside an invoke handler to answer a typed bridge error.
(struct exn:fail:glaze:bridge exn:fail (code data) #:transparent)

(define (raise-bridge-error code [message #f] [data #f])
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
(define (build-invoke-response id result)
  (hasheq 'glz glz1-version 'id id 'ok #t 'value result))

;; GET /glaze/hello — what a frontend checks before its first invoke.
(define (build-hello routes [app-id #f])
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
                                                "/"))))))

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
