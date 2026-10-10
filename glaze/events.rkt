#lang racket/base

;; Backend -> frontend event push: a broadcast bus consumed by the SSE
;; endpoint that start-server mounts at /glaze/events (Glaze's answer to
;; Tauri's emit() and Eel's websocket push — plain SSE on the same local
;; origin used by the embedded WebView).
;;
;;   (define bus (make-event-bus))
;;   (start-server #:public-dir "public" #:events bus ...)
;;   ...later, from any thread:
;;   (bus-broadcast! bus 'counter-changed (hasheq 'count 42))
;;
;; In the page:
;;   const es = new EventSource('/glaze/events');
;;   es.addEventListener('counter-changed', e => e.detail);
;;
;; Overflow policy: a bounded backlog keeps a slow client from growing server
;; memory. When it fills, the OLDEST queued event is sacrificed for the new
;; one (a lagging UI wants the freshest state, not the stalest), every drop
;; is counted (bus-dropped-count), and the first drop in a burst is reported
;; through current-event-drop-reporter. Drops are observable, never silent.

(require racket/async-channel)

(provide make-event-bus
         event-bus?
         bus-broadcast!
         bus-subscribe!
         bus-unsubscribe!
         bus-subscriber-count
         bus-dropped-count
         current-event-drop-reporter
         bus-wait)

(struct event-bus (channels sema dropped last-drop-report) #:transparent)

(define backlog 256)

(define current-event-drop-reporter
  (make-parameter
   (lambda (dropped name)
     (fprintf (current-error-port)
              "[glaze] event bus backlog full: dropped ~a event(s) so far; last dropped event: ~a\n"
              dropped
              name))))

(define (make-event-bus)
  (event-bus (make-hasheq) (make-semaphore 1) (box 0) (box 0.0)))

(define (bus-subscribe! bus)
  (define ch (make-async-channel backlog))
  (call-with-semaphore (event-bus-sema bus) (lambda () (hash-set! (event-bus-channels bus) ch #t)))
  ch)

(define (bus-unsubscribe! bus ch)
  (call-with-semaphore (event-bus-sema bus) (lambda () (hash-remove! (event-bus-channels bus) ch))))

(define (bus-subscriber-count bus)
  (call-with-semaphore (event-bus-sema bus) (lambda () (hash-count (event-bus-channels bus)))))

(define (bus-dropped-count bus)
  (unbox (event-bus-dropped bus)))

;; Report at most once per interval per bus, so a wedged subscriber produces
;; a warning instead of a log line per broadcast. The reporter runs while the
;; bus semaphore is held — it must not call bus-* functions.
(define drop-report-interval-ms 5000)

(define (maybe-report-drop! bus name)
  (set-box! (event-bus-dropped bus) (add1 (unbox (event-bus-dropped bus))))
  (define now (current-inexact-milliseconds))
  (when (>= (- now (unbox (event-bus-last-drop-report bus))) drop-report-interval-ms)
    (set-box! (event-bus-last-drop-report bus) now)
    (with-handlers ([exn:fail? (lambda (_) (void))])
      ((current-event-drop-reporter) (unbox (event-bus-dropped bus)) name))))

;; Deliver (name . jsexpr) to every subscriber. Non-blocking: a full backlog
;; drops the subscriber's OLDEST event to make room (the stale one), which is
;; the right trade for UI state. The get+put pair runs under the bus
;; semaphore so concurrent broadcasters cannot race the swap; between a
;; failed put and the swap the subscriber may have drained the queue, in
;; which case the swap sacrifices the then-newest event — rare, and still a
;; drop, not a corruption.
(define (bus-broadcast! bus name data)
  (unless (or (symbol? name) (string? name))
    (raise-argument-error 'bus-broadcast! "(or/c symbol? string?)" name))
  (define payload
    (list (if (string? name)
              (string->symbol name)
              name)
          data))
  (define snapshot
    (call-with-semaphore (event-bus-sema bus) (lambda () (hash-keys (event-bus-channels bus)))))
  (for ([ch (in-list snapshot)])
    (unless (sync/timeout 0 (async-channel-put-evt ch payload))
      (call-with-semaphore (event-bus-sema bus)
        (lambda ()
          (unless (sync/timeout 0 (async-channel-put-evt ch payload))
            (async-channel-get ch)
            (sync/timeout 0 (async-channel-put-evt ch payload))
            (maybe-report-drop! bus (car payload))))))))

;; Blocking receive with timeout — for tests and non-SSE consumers.
;; Returns (list name data) or 'timeout.
(define (bus-wait ch [secs 10])
  (or (sync/timeout secs ch) 'timeout))
