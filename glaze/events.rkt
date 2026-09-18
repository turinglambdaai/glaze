#lang racket/base

;; Backend -> frontend event push: a broadcast bus consumed by the SSE
;; endpoint that start-server mounts at /glaze/events (Glaze's answer to
;; Tauri's emit() and Eel's websocket push — plain SSE on the same origin,
;; so the browser fallback gets push for free).
;;
;;   (define bus (make-event-bus))
;;   (start-server #:public-dir "public" #:events bus ...)
;;   ...later, from any thread:
;;   (bus-broadcast! bus 'counter-changed (hasheq 'count 42))
;;
;; In the page:
;;   const es = new EventSource('/glaze/events');
;;   es.addEventListener('counter-changed', e => e.detail);

(require json
         racket/async-channel)

(provide make-event-bus
         event-bus?
         bus-broadcast!
         bus-subscribe!
         bus-unsubscribe!
         bus-wait)

;; Subscribers are bounded async channels of (list name jsexpr). A bounded
;; backlog keeps a slow client from growing server memory; on overflow the
;; event is dropped for that subscriber only (right trade for UI events).
(struct event-bus (channels sema) #:transparent)

(define backlog 256)

(define (make-event-bus)
  (event-bus (make-hasheq) (make-semaphore 1)))

(define (bus-subscribe! bus)
  (define ch (make-async-channel backlog))
  (call-with-semaphore (event-bus-sema bus)
                       (lambda () (hash-set! (event-bus-channels bus) ch #t)))
  ch)

(define (bus-unsubscribe! bus ch)
  (call-with-semaphore (event-bus-sema bus)
                       (lambda () (hash-remove! (event-bus-channels bus) ch))))

;; Deliver (name . jsexpr) to every subscriber. Non-blocking: a full
;; backlog drops the event for that subscriber only.
(define (valid-event-name? name)
  (define s
    (cond
      [(symbol? name) (symbol->string name)]
      [(string? name) name]
      [else #f]))
  (and s
       (positive? (string-length s))
       (not (regexp-match? #rx"[\r\n\u0000]" s))))

(define (bus-broadcast! bus name data)
  (unless (valid-event-name? name)
    (raise-argument-error
     'bus-broadcast!
     "non-empty symbol/string without CR, LF, or NUL"
     name))
  (unless (jsexpr? data)
    (raise-argument-error 'bus-broadcast! "jsexpr?" data))
  (define payload
    (list (if (string? name) (string->symbol name) name) data))
  (define snapshot
    (call-with-semaphore (event-bus-sema bus)
                         (lambda () (hash-keys (event-bus-channels bus)))))
  (for ([ch (in-list snapshot)])
    (sync/timeout 0 (async-channel-put-evt ch payload))))

;; Blocking receive with timeout — for tests and non-SSE consumers.
;; Returns (list name data) or 'timeout.
(define (bus-wait ch [secs 10])
  (unless (and (real? secs) (>= secs 0))
    (raise-argument-error 'bus-wait "nonnegative-real?" secs))
  (or (sync/timeout secs ch) 'timeout))
