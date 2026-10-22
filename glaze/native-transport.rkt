#lang racket/base

;; The native host transport (docs/architecture.md) and the pieces the
;; HTTP development adapter shares with it.
;;
;; In a packaged app the WebView never talks to a TCP port. The page loads
;; its frontend resources from a controlled scheme (glaze://app/... served by
;; the host's WKURLSchemeHandler / WebView2 equivalent) and calls the backend
;; through the WebView's native message handler with the same GLZ1 envelopes
;; the HTTP adapter speaks. The loopback HTTP server survives as the
;; development adapter (hot reload, curl, tests); it is no longer the
;; production trust boundary.
;;
;; Transport-neutral responsibilities are private owners imported and
;; re-exported here for compatibility:
;;
;;   - dispatch-bridge / dispatch-invoke: GLZ1 envelope dispatch (op-routed
;;     hello / cancel / invoke) against the route table, with typed errors,
;;     cooperative cancellation, bounded timeouts, and capability checks —
;;     the exact pipeline server.rkt used to own, now in
;;     private/bridge-dispatch.rkt;
;;   - static-resource: the static file rules (string segments only,
;;     filesystem containment, SPA index fallback, MIME table, now in
;;     private/native-resources.rkt;
;;   - native-api-client-js / native-bootstrap-js: the page-side bindings
;;     that make the generated glaze.api entries and event delivery run over
;;     the message handler instead of fetch/EventSource, now in
;;     private/native-client.rkt.
;;   - native-delivery: full-response, stream, and event framing plus
;;     UTF-8-safe stream draining, now in private/native-delivery.rkt.
;;
;; The host side (per platform) only has to: serve scheme resources through
;; static-resource, feed message-handler payloads into
;; native-transport-message!, and deliver the returned JavaScript snippets
;; back into the page on the UI thread (native-transport-deliver!).

(require json
         racket/async-channel
         racket/list
         racket/match
         (only-in web-server/http/response-structs response?)
         "api.rkt"
         "bridge.rkt"
         "capability.rkt"
         "events.rkt"
         "private/bridge-dispatch.rkt"
         "private/native-client.rkt"
         "private/native-delivery.rkt"
         "private/native-resources.rkt")

(provide dispatch-bridge
         dispatch-invoke
         synthetic-request
         static-resource
         path->mime-type
         current-glaze-error-reporter
         glz1-error-envelope
         native-transport?
         native-transport-routes
         native-delivery
         native-delivery-js
         native-delivery-json
         start-native-transport
         native-transport-message!
         native-transport-message-deferred!
         native-transport-take-deferred!
         native-transport-set-deliver!
         native-transport-public-dir
         native-transport-stats
         native-transport-count-resource!
         native-transport-shutdown!
         native-scheme-segments
         native-app-origin
         generate-api-declarations
         route-named-types
         native-api-client-js
         native-bootstrap-js)

;; ---- native transport instance ----

;; One per window (per open-app call): receives message-handler payloads,
;; dispatches each on its own thread, and hands JavaScript snippets to the
;; host through the deliver! hook the platform wiring installs.
(struct native-transport
        (routes ; (listof route?)
         authority ; #f or capability?
         bus ; #f or event-bus?
         public-dir ; path-string? — scheme resources are served from here
         table ; request table (cancellation), per transport
         inbox ; box of (listof string) — FFI-safe message inbox, see message!
         control ; async channel for the event thread's shutdown
         deliver-box ; box of (string? js) -> void — set by the host wiring
         stats-box ; box of immutable hash — served/delivered counters
         threads-box ; box of (listof thread?) — dispatcher + event thread
         streams-box ; box of (hash id -> output-port) — active streams
         lifecycle-lock ; serializes stop, stream registry, and delivery gates
         state-box ; 'running, 'stopping, or 'stopped (protected by lifecycle-lock)
         shutdown-done ; broadcast event for concurrent idempotent shutdown callers
         deferred-box) ; box of (listof string) — FFI-stack message stash
  #:transparent)

(define (bump-stat! t key)
  (define box (native-transport-stats-box t))
  (set-box! box (hash-update (unbox box) key add1 0)))

(define (native-transport-running? t)
  (call-with-semaphore
   (native-transport-lifecycle-lock t)
   (lambda () (eq? (unbox (native-transport-state-box t)) 'running))))

;; All page-facing deliveries pass this gate. The callback is kept inside the
;; lifecycle lock so shutdown cannot return while an earlier delivery is still
;; in flight; callbacks should enqueue host/UI work rather than re-enter stop.
(define (native-transport-deliver! t delivery)
  (call-with-semaphore
   (native-transport-lifecycle-lock t)
   (lambda ()
     (when (eq? (unbox (native-transport-state-box t)) 'running)
       ((unbox (native-transport-deliver-box t)) delivery))))
  (void))

(define (start-native-transport #:api routes
                                #:authority [authority #f]
                                #:events [bus #f]
                                #:public-dir [public-dir "public"])
  (when (and authority (not (capability? authority)))
    (raise-argument-error 'start-native-transport "(or/c #f capability?)" authority))
  (when (and bus (not (event-bus? bus)))
    (raise-argument-error 'start-native-transport "event-bus?" bus))
  (define t
    (native-transport
     routes
     authority
     bus
     public-dir
     (make-request-table)
     (make-async-channel #f)
     (make-async-channel 1)
     (box void)
     (box
      (hasheq 'resources-served 0 'messages-received 0 'responses-delivered 0 'events-delivered 0))
     (box '())
     (box (make-hash))
     (make-semaphore 1)
     (box 'running)
     (make-semaphore 0)
     (box '())))
  ;; The dispatcher inherits the caller's parameterization (custodian, error
  ;; reporter) and spawns one thread per message, so a slow or timing-out
  ;; invoke never blocks other invokes or cancels.
  (define dispatcher (thread (lambda () (dispatcher-loop t))))
  ;; Subscribe BEFORE returning: an event broadcast right after
  ;; start-native-transport must be seen, exactly like the HTTP adapter's
  ;; SSE endpoint that is mounted before start-server returns.
  (define event-ch (and bus (bus-subscribe! bus)))
  (define event-thread (and bus (thread (lambda () (event-loop t event-ch)))))
  (set-box! (native-transport-threads-box t) (filter values (list dispatcher event-thread)))
  t)

(define (dispatcher-loop t)
  (let loop ()
    (define raw (async-channel-get (native-transport-inbox t)))
    (thread (lambda () (handle-raw-message! t raw)))
    (loop)))

;; Script-message callbacks arrive while the host's thread is inside a
;; foreign call (macOS runs the main run loop on the pump thread, so the
;; WebKit callbacks reenter Racket on the pump thread's FFI stack). A
;; scheduler operation that has to yield there — async-channel-put racing
;; the dispatcher's get — raises "attempt to deschedule the current thread
;; in atomic mode" and kills the process. So a callback may only stash the
;; payload in this box, and the host's pump loop hands the stash to the
;; dispatcher from full Racket context. The writer and the drainer are the
;; same thread on every platform (the pump thread owns the run loop /
;; event pump that reenters), so plain pointer swaps are race-free.
(define (native-transport-message-deferred! t raw)
  ;; This is called re-entrantly on macOS's FFI callback stack. Never acquire a
  ;; semaphore here: that can deschedule an atomic callback and kill the host.
  ;; The platform pump thread also owns the matching take-deferred! operation.
  (define b (native-transport-deferred-box t))
  (when (eq? (unbox (native-transport-state-box t)) 'running)
    (set-box! b (cons raw (unbox b)))
    ;; Shutdown may race this non-blocking callback from another thread. Recheck
    ;; after the pointer swap so a late append cannot retain stale work.
    (unless (eq? (unbox (native-transport-state-box t)) 'running)
      (set-box! b '())))
  (void))

(define (native-transport-take-deferred! t)
  (call-with-semaphore
   (native-transport-lifecycle-lock t)
   (lambda ()
     (let ([b (native-transport-deferred-box t)])
       (if (eq? (unbox (native-transport-state-box t)) 'running)
           (let ([batch (reverse (unbox b))])
             (set-box! b '())
             batch)
           (begin
             (set-box! b '())
             '())))))

;; Parse a raw message-handler payload (a JSON text from the page) and answer
;; through the host's deliver! hook. Parse failures become typed envelopes,
;; never host-side exceptions.
(define (handle-raw-message! t raw)
  (when (native-transport-running? t)
    (bump-stat! t 'messages-received)
    (let* ([body
            (with-handlers ([exn:fail? (lambda (_) (hasheq))])
              (cond
                [(not (string? raw)) (hasheq)]
                [else (string->jsexpr raw)]))]
           [dispatch
            (lambda ()
              (with-handlers
                  ([exn:fail?
                    (lambda (e)
                      ((current-glaze-error-reporter) e "glz1:native")
                      (glz1-error-envelope #f 'internal "internal error" 'null))])
                (dispatch-bridge body
                                 (native-transport-routes t)
                                 (native-transport-authority t)
                                 (native-transport-table t)
                                 route->js-name
                                 (unbox (native-transport-streams-box t)))))]
           [response
            ;; Cancellation is the only bridge operation that touches the
            ;; active-stream hash. Serialize it with stream registration and
            ;; shutdown; normal route handlers remain concurrent.
            (if (and (hash? body) (equal? (hash-ref body 'op #f) "cancel"))
                (call-with-semaphore
                 (native-transport-lifecycle-lock t)
                 (lambda ()
                   (and (eq? (unbox (native-transport-state-box t)) 'running)
                        (dispatch))))
                (dispatch))])
      (when response
        (cond
          ;; A streaming response is framed by the reader thread while the
          ;; writer runs independently; registration is atomic with shutdown.
          [(response? response)
           (bump-stat! t 'responses-delivered)
           (define id (and (hash? body)
                           (let ([v (hash-ref body 'id #f)])
                             (and (string? v) v))))
           (define streams (unbox (native-transport-streams-box t)))
           (deliver-stream-response!
            response
            id
            streams
            (lambda (delivery) (native-transport-deliver! t delivery))
            #:register-stream!
            (lambda (stream-id port)
              (call-with-semaphore
               (native-transport-lifecycle-lock t)
               (lambda ()
                 (if (eq? (unbox (native-transport-state-box t)) 'running)
                     (begin
                       (hash-set! streams stream-id port)
                       #t)
                     #f))))
            #:unregister-stream!
            (lambda (stream-id)
              (call-with-semaphore
               (native-transport-lifecycle-lock t)
               (lambda () (hash-remove! streams stream-id)))))]
          ;; Full envelopes use one delivery frame.
          [else
           (bump-stat! t 'responses-delivered)
           (native-transport-deliver! t (response-delivery response))])))))

(define (event-loop t ch)
  (define bus (native-transport-bus t))
  (let loop ()
    ;; Put the control event first so a sustained event backlog cannot starve
    ;; shutdown after the transport has stopped accepting new deliveries.
    (define v (sync (native-transport-control t) ch))
    (cond
      [(eq? v 'shutdown) (bus-unsubscribe! bus ch)]
      [else
       (match-define (list seq name data) v)
       (bump-stat! t 'events-delivered)
       ;; One non-serializable payload must not kill the event thread (it
       ;; would silently stop every future delivery): report and skip.
       (with-handlers ([exn:fail? (lambda (e)
                                    ((current-glaze-error-reporter) e "glz1:native:event"))])
         (native-transport-deliver! t (event-delivery seq name data)))
       (loop)])))

;; Called by the host's message handler when it runs on a full Racket
;; thread (Windows' window procedure and Linux's GTK callbacks execute on
;; the host's pump thread, outside any foreign stack). macOS callbacks
;; reenter on the pump thread's FFI stack instead and must use
;; native-transport-message-deferred!.
(define (native-transport-message! t raw)
  ;; Enqueue and shutdown share one lock: messages submitted after stopping are
  ;; ignored, while an earlier accepted message may be abandoned at teardown.
  (call-with-semaphore
   (native-transport-lifecycle-lock t)
   (lambda ()
     (when (eq? (unbox (native-transport-state-box t)) 'running)
       (async-channel-put (native-transport-inbox t) raw))))
  (void))

;; The host wiring installs this once it has a WebView handle: deliver! runs
;; on any transport thread and must hop the snippet to the UI thread.
(define (native-transport-set-deliver! t deliver!)
  (unless (procedure? deliver!)
    (raise-argument-error 'native-transport-set-deliver! "procedure?" deliver!))
  (set-box! (native-transport-deliver-box t) deliver!))

(define (native-transport-stats t)
  (unbox (native-transport-stats-box t)))

;; The host's scheme handler reports each served resource so tests can
;; observe that the page actually loaded through the controlled scheme.
(define (native-transport-count-resource! t)
  (bump-stat! t 'resources-served))

;; Stop the dispatcher and event threads. In-flight handler threads were
;; spawned under the caller's custodian and die with it (run-app teardown).
(define (native-transport-shutdown! t)
  ;; Exactly one caller owns cleanup; concurrent callers wait for its
  ;; completion, and later calls return immediately.
  (define-values (action threads ports)
    (call-with-semaphore
     (native-transport-lifecycle-lock t)
     (lambda ()
       (case (unbox (native-transport-state-box t))
         [(running)
          (define threads (unbox (native-transport-threads-box t)))
          (define streams (unbox (native-transport-streams-box t)))
          (define ports (hash-values streams))
          (set-box! (native-transport-state-box t) 'stopping)
          (set-box! (native-transport-threads-box t) '())
          (hash-clear! streams)
          (set-box! (native-transport-deferred-box t) '())
          (values 'owner threads ports)]
         [(stopping) (values 'wait '() '())]
         [else (values 'done '() '())]))))
  (case action
    [(owner)
     (dynamic-wind
      void
      (lambda ()
        ;; Closing the registered writer ports makes streaming-response
        ;; writers unwind; delivery gates suppress any late terminal frames.
        (for ([port (in-list ports)])
          (with-handlers ([exn:fail? (lambda (_) (void))])
            (close-output-port port)))
        (let* ([dispatcher (and (pair? threads) (car threads))]
               [event-thread
                (and (native-transport-bus t)
                     (pair? (cdr threads))
                     (cadr threads))])
          (when event-thread
            (async-channel-put (native-transport-control t) 'shutdown)
            (thread-wait event-thread))
          (when dispatcher
            (with-handlers ([exn:fail? (lambda (_) (void))])
              (kill-thread dispatcher))
            (thread-wait dispatcher))))
      (lambda ()
        (call-with-semaphore
         (native-transport-lifecycle-lock t)
         (lambda () (set-box! (native-transport-state-box t) 'stopped)))
        (semaphore-post (native-transport-shutdown-done t))))]
    [(wait) (sync (semaphore-peek-evt (native-transport-shutdown-done t)))]
    [else (void)])
  (void))
