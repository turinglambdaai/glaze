#lang racket/base

;; JS <-> Racket bridge example: the page calls `fetch("/api/counter")`
;; and Racket answers JSON — Glaze's answer to Tauri's invoke(). State lives
;; in Racket (a box); the frontend is a pure view.
;;
;; Run: racket examples/counter/main.rkt

(require racket/list
         racket/runtime-path
         glaze)

(define-runtime-path public "public")

;; Racket-side state.
(define count (box 0))
(define history '())

(define (bump! delta)
  (set-box! count (max 0 (+ (unbox count) delta)))
  (set! history (cons (unbox count) (take history (min 9 (length history)))))
  (hasheq 'count (unbox count) 'history (reverse history)))

(define (reset!)
  (set-box! count 0)
  (set! history '())
  (hasheq 'count (unbox count) 'history '()))

(module+ main
  (run-app
   #:public-dir public
   #:title "Counter · Glaze"
   #:api (list
          ;; POST /api/counter/bump  body {"delta": 1}
          ;; (Racket jsexpr parses JSON object keys as symbols)
          (POST "api/counter/bump"
                (lambda (req)
                  (define body (request-json-body req))
                  (bump! (if (hash? body)
                             (hash-ref body 'delta 1)
                             1))))
          ;; POST /api/counter/reset
          (POST "api/counter/reset" (lambda (req) (reset!)))
          ;; GET /api/counter
          (GET "api/counter"
               (lambda (req)
                 (hasheq 'count (unbox count) 'history (reverse history)))))))
