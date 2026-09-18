#lang racket/base

(require rackunit
         glaze/api)

;; Leading/trailing slashes are normalized.
(define normalized
  (GET "/api/items/:id/" (lambda (req id) id)))
(check-equal? (route-match normalized 'GET '("api" "items" "42")) '("42"))

;; Invalid route declarations fail during application setup rather than on the
;; first request.
(check-exn exn:fail?
           (lambda () (GET "" (lambda (req) #f))))
(check-exn exn:fail?
           (lambda () (GET "api/:" (lambda (req x) x))))
(check-exn exn:fail?
           (lambda () (GET "api/../secret" (lambda (req) #f))))
(check-exn exn:fail?
           (lambda () (GET "api/:id" (lambda (req) #f))))

;; Public response helpers have deterministic contracts.
(check-exn exn:fail:contract?
           (lambda () (api-response (lambda () #t))))
(check-exn exn:fail:contract?
           (lambda () (error-response 99 "bad")))
(check-exn exn:fail:contract?
           (lambda () (error-response 500 'bad)))
(check-exn exn:fail:contract?
           (lambda () (route-match 'not-a-route 'GET '("api"))))
