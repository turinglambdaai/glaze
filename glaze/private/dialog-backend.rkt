#lang racket/base

;; Dialog backend injection value: the struct plumbing behind
;; make-dialog-routes, so tests and headless CI can substitute a fake
;; backend. Internalized behind glaze/private by G3-S2
;; (docs/api-stability.md) — never public API. The platform-bound
;; `default-dialog-backend` stays in glaze/dialogs next to the native
;; functions it wraps.

(provide (struct-out dialog-backend)
         make-dialog-backend)

;; Backends are values so tests (and headless CI) can substitute a fake.
(struct dialog-backend (pick-file pick-files pick-folder save message! ask!))

;; Explicit constructor: `provide` cannot forward-reference the implicit
;; struct constructor (same shape as make-capability / make-hotkey-backend).
(define (make-dialog-backend pick-file pick-files pick-folder save message! ask!)
  (unless (andmap procedure? (list pick-file pick-files pick-folder save message! ask!))
    (raise-argument-error 'make-dialog-backend
                          "list of procedures"
                          (list pick-file pick-files pick-folder save message! ask!)))
  (dialog-backend pick-file pick-files pick-folder save message! ask!))
