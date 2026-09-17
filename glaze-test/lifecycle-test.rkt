#lang racket/base

(require rackunit
         (submod glaze/app test-support))

;; shutdown is part of run-app's returned lifecycle contract: callers are free
;; to call it even after run-app already stopped the server on window close.
(define calls 0)
(define shutdown
  (make-idempotent-shutdown
   (lambda ()
     (set! calls (add1 calls)))))

(shutdown)
(shutdown)
(shutdown)
(check-equal? calls 1 "underlying shutdown runs at most once")

;; Concurrent callers must also collapse to one underlying shutdown.
(define concurrent-calls 0)
(define concurrent-shutdown
  (make-idempotent-shutdown
   (lambda ()
     (sleep 0.02)
     (set! concurrent-calls (add1 concurrent-calls)))))
(define workers
  (for/list ([i (in-range 8)])
    (thread concurrent-shutdown)))
(for-each thread-wait workers)
(check-equal? concurrent-calls 1 "concurrent shutdown calls are serialized and idempotent")

;; A failed underlying shutdown is not recorded as complete, so a caller may
;; retry rather than being left with a permanently half-stopped runtime.
(define attempts 0)
(define retryable-shutdown
  (make-idempotent-shutdown
   (lambda ()
     (set! attempts (add1 attempts))
     (when (= attempts 1)
       (error 'test "first shutdown attempt fails")))))
(check-exn exn:fail? retryable-shutdown)
(check-not-exn retryable-shutdown)
(retryable-shutdown)
(check-equal? attempts 2 "successful retry becomes the final shutdown")
