#lang racket/base

;; Hotkey backend injection value: the struct plumbing behind
;; make-global-shortcut-routes, so tests and apps with their own dispatch
;; policy can substitute a fake. Internalized behind glaze/private by G3-S2
;; (docs/api-stability.md) — never public API. The platform-bound
;; `default-hotkey-backend` stays in glaze/global-shortcut next to the
;; platform dispatch it delegates to.

(provide (struct-out hotkey-backend)
         make-hotkey-backend)

(struct hotkey-backend (supported? register! unregister! unregister-all! registered?))

;; Explicit constructor: `provide` cannot forward-reference the implicit
;; struct constructor (same shape as make-capability in capability.rkt).
(define (make-hotkey-backend supported? register! unregister! unregister-all! registered?)
  (unless (andmap procedure? (list supported? register! unregister! unregister-all! registered?))
    (raise-argument-error 'make-hotkey-backend
                          "list of procedures"
                          (list supported? register! unregister! unregister-all! registered?)))
  (hotkey-backend supported? register! unregister! unregister-all! registered?))
