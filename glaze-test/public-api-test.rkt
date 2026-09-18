#lang racket/base

(require rackunit
         glaze)

;; The application-facing contract is that normal Glaze apps can start from a
;; single `(require glaze)`.  Keep this test intentionally shallow: subsystem
;; behavior belongs in focused tests; this file protects the facade itself.

(check-true (procedure? run-app) "glaze exports run-app")
(check-true (procedure? start-server) "glaze exports start-server")
(check-true (procedure? open-window) "glaze exports open-window")
(check-true (procedure? make-tray) "glaze exports make-tray")
(check-true (procedure? make-event-bus) "glaze exports make-event-bus")
(check-true (procedure? bus-broadcast!) "glaze exports bus-broadcast!")
(check-true (procedure? clipboard-set!) "glaze exports system capabilities")
(check-true (procedure? build-app) "glaze exports packaging helpers")

;; Platform-independent smoke behavior through the facade.
(define bus (make-event-bus))
(define subscriber (bus-subscribe! bus))
(bus-broadcast! bus 'facade-smoke (hasheq 'ok #t))
(check-equal? (bus-wait subscriber 1)
              (list 'facade-smoke (hasheq 'ok #t)))
(bus-unsubscribe! bus subscriber)

;; Public argument validation should remain visible through the facade.
(check-exn exn:fail:contract?
           (lambda () (bus-broadcast! bus 42 (hasheq))))
