#lang racket/base

;; The native host transport (docs/architecture-1.0.md) and the pieces the
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
         deferred-box) ; box of (listof string) — FFI-stack message stash
  #:transparent)

(define (bump-stat! t key)
  (define box (native-transport-stats-box t))
  (set-box! box (hash-update (unbox box) key add1 0)))

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
  (define b (native-transport-deferred-box t))
  (set-box! b (cons raw (unbox b))))

(define (native-transport-take-deferred! t)
  (define b (native-transport-deferred-box t))
  (define batch (reverse (unbox b)))
  (unless (null? batch)
    (set-box! b '()))
  batch)

;; Parse a raw message-handler payload (a JSON text from the page) and answer
;; through the host's deliver! hook. Parse failures become typed envelopes,
;; never host-side exceptions.
(define (handle-raw-message! t raw)
  (bump-stat! t 'messages-received)
  (define body
    (with-handlers ([exn:fail? (lambda (_) (hasheq))])
      (cond
        [(not (string? raw)) (hasheq)]
        [else (string->jsexpr raw)])))
  (define response
    (with-handlers ([exn:fail? (lambda (e)
                                 ((current-glaze-error-reporter) e "glz1:native")
                                 (glz1-error-envelope #f 'internal "internal error" 'null))])
      (dispatch-bridge body
                       (native-transport-routes t)
                       (native-transport-authority t)
                       (native-transport-table t)
                       route->js-name
                       (unbox (native-transport-streams-box t)))))
  (cond
    ;; A streaming-response handler (web-server response struct) cannot be
    ;; one envelope: the writer runs on its own thread, this dispatcher
    ;; worker drains the pipe and forwards chunk frames, and per-message
    ;; threads keep other invokes flowing meanwhile.
    [(response? response)
     (bump-stat! t 'responses-delivered)
     (define id (and (hash? body) (let ([v (hash-ref body 'id #f)]) (and (string? v) v))))
     (define deliver! (unbox (native-transport-deliver-box t)))
     (define streams (unbox (native-transport-streams-box t)))
     (deliver-stream-response! response id streams deliver!)]
    ;; Everything else is a full envelope jsexpr: one frame.
    [else
     (bump-stat! t 'responses-delivered)
     ((unbox (native-transport-deliver-box t)) (response-delivery response))]))

(define (event-loop t ch)
  (define bus (native-transport-bus t))
  (let loop ()
    (define v (sync ch (native-transport-control t)))
    (cond
      [(eq? v 'shutdown) (bus-unsubscribe! bus ch)]
      [else
       (match-define (list seq name data) v)
       (bump-stat! t 'events-delivered)
       ;; One non-serializable payload must not kill the event thread (it
       ;; would silently stop every future delivery): report and skip.
       (with-handlers ([exn:fail? (lambda (e)
                                    ((current-glaze-error-reporter) e "glz1:native:event"))])
         ((unbox (native-transport-deliver-box t)) (event-delivery seq name data)))
       (loop)])))

;; Called by the host's message handler when it runs on a full Racket
;; thread (Windows' window procedure and Linux's GTK callbacks execute on
;; the host's pump thread, outside any foreign stack). macOS callbacks
;; reenter on the pump thread's FFI stack instead and must use
;; native-transport-message-deferred!.
(define (native-transport-message! t raw)
  (async-channel-put (native-transport-inbox t) raw))

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
  ;; Idempotent: the host close path and run-app teardown both call this.
  ;; With no event bus nobody consumes the control channel, so a second
  ;; put would block forever on a full channel — only fire when threads
  ;; are still registered.
  (define threads (unbox (native-transport-threads-box t)))
  (unless (null? threads)
    (async-channel-put (native-transport-control t) 'shutdown)
    (for ([th (in-list threads)])
      (with-handlers ([exn:fail? (lambda (_) (void))])
        (kill-thread th)))
    (set-box! (native-transport-threads-box t) '())))
