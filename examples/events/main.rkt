#lang racket/base

;; Minimal request + event example using Glaze's existing HTTP/SSE bridge.
;; Run: racket examples/events/main.rkt

(require racket/runtime-path
         glaze)

(define-runtime-path public "public")
(define bus (make-event-bus))

(define-api-routes api
  [(POST "api/ping")
   (ping)
   (begin
     (bus-broadcast! bus 'pong (hasheq 'message "pong from Racket"))
     (hasheq 'ok #t))])

(module+ main
  (run-app #:public-dir public
           #:api api
           #:events bus
           #:title "Glaze Events"))
