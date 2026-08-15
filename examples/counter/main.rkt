#lang racket/base

;; JS <-> Racket bridge example, full stack: define-api-routes (typed
;; params + generated JS client + callable Racket procs) and event push
;; (bus-broadcast! -> EventSource). The page is a pure view.
;;
;; Run: racket examples/counter/main.rkt

(require racket/list
         racket/runtime-path
         glaze)

(define-runtime-path public "public")

;; Composability: expose the routes and bus so other modules (and tests)
;; can reuse them without launching the app.

;; Racket-side state.
(define count (box 0))
(define history '())
(define bus (make-event-bus))

(define (notify!)
  (bus-broadcast! bus 'count-changed
                  (hasheq 'count (unbox count) 'history (reverse history))))

(define-api-routes api
  [(POST "api/counter/bump")
   (bump [delta exact-nonnegative-integer? 1])
   (begin
     (set-box! count (max 0 (+ (unbox count) delta)))
     (set! history (cons (unbox count) (take history (min 9 (length history)))))
     (notify!)
     (hasheq 'count (unbox count) 'history (reverse history)))]
  [(POST "api/counter/reset")
   (reset)
   (begin
     (set-box! count 0)
     (set! history '())
     (notify!)
     (hasheq 'count 0 'history '()))]
  [(GET "api/counter")
   (counter)
   (hasheq 'count (unbox count) 'history (reverse history))])

(module+ main
  (run-app
   #:public-dir public
   #:api api
   #:events bus
   #:title "Counter · Glaze"))

(provide api bus)
