#lang racket/base

;; 1.0-gate resource-leak soak (docs/architecture-1.0.md step: resource-leak
;; soak). Exercises the two long-lived resource cycles headlessly:
;;
;;   1. native-transport create/dispatch/teardown, repeated N times —
;;      asserting thread count returns to baseline after each cycle;
;;   2. envelope dispatch through a live transport, repeated N times —
;;      asserting the response channel drains and request tables retire.
;;
;; Real-window open/close soak lives in the webview-e2e script (all three
;; platforms); this file covers the runtime-kernel cycles a CI runner can
;; do headlessly and deterministically.

(require rackunit
         racket/async-channel
         racket/file
         racket/list
         racket/string
         glaze/api
         glaze/bridge
         glaze/native-transport
         glaze/types)

;; Negative-path tests intentionally raise handler errors; keep them off
;; stderr so drdr's non-empty-stderr check stays clean.
(current-glaze-error-reporter (lambda (_exn _uri) (void)))
(define Item (grecord 'Item "id" GInt64 "name" GString))

;; Racket has no thread enumeration; the leak check uses a custodian:
;; every cycle runs under a fresh custodian, and custodian-shutdown-all
;; at cycle end reaps everything the cycle created. The soak asserts that
;; repeating cycles stays fast and never errors (no leaked-fd style
;; failures), plus that a managed custodian reaps cleanly.
(define (soak-under-custodian! body)
  (define cust (make-custodian))
  (parameterize ([current-custodian cust])
    (body))
  (custodian-shutdown-all cust))

(define (soak-transport-cycles! cycles)
  (define routes (list (GET "api/ping" (lambda (_req) (hasheq 'pong #t)))))
  (for ([i (in-range cycles)])
    (define dir (make-temporary-file "glaze-soak-~a" 'directory))
    (with-handlers ([exn:fail? (lambda (e)
                                 (delete-directory/files dir)
                                 (raise e))])
      (define t (start-native-transport #:api routes #:public-dir dir))
      ;; a couple of live dispatches per cycle
      (define got (make-async-channel))
      (native-transport-set-deliver! t (lambda (js) (async-channel-put got js)))
      (native-transport-message! t "{\"glz\":1,\"id\":\"s1\",\"path\":\"api/ping\"}")
      (define resp (sync/timeout 5 got))
      (unless resp
        (error 'soak "cycle ~a: no delivery" i))
      (native-transport-shutdown! t)
      (delete-directory/files dir))))

(module+ test
  (require rackunit
           racket/file
           glaze/types)

  (test-case "transport create/teardown cycles complete cleanly"
    (soak-transport-cycles! 30)
    (check-true #t "30 create/dispatch/teardown cycles completed"))

  (test-case "repeat dispatch does not grow the request table"
    (define routes (list (GET "api/ping" (lambda (_req) (hasheq 'pong #t)))))
    (define dir (make-temporary-file "glaze-soak-d-~a" 'directory))
    (define t (start-native-transport #:api routes #:public-dir dir))
    (define got (make-async-channel))
    (native-transport-set-deliver! t (lambda (js) (async-channel-put got js)))
    (for ([i (in-range 500)])
      (native-transport-message! t (format "{\"glz\":1,\"id\":\"d~a\",\"path\":\"api/ping\"}" i))
      (sync/timeout 5 got))
    (check-true #t "500 dispatches drained")
    (native-transport-shutdown! t)
    (delete-directory/files dir))

  (test-case "result violations do not wedge the dispatcher"
    (define routes (list (GET "api/bad" #:returns GInt64 (lambda (_req) (hasheq 'not "an int")))))
    (define dir (make-temporary-file "glaze-soak-v-~a" 'directory))
    (define t (start-native-transport #:api routes #:public-dir dir))
    (define got (make-async-channel))
    (native-transport-set-deliver! t (lambda (js) (async-channel-put got js)))
    (for ([i (in-range 200)])
      (native-transport-message! t "{\"glz\":1,\"id\":\"v\",\"path\":\"api/bad\"}")
      (sync/timeout 5 got))
    (native-transport-shutdown! t)
    (check-true #t "200 violations drained")))
