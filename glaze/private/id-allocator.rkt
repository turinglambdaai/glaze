#lang racket/base

;; Id allocator mapping native menu ids back to Racket callbacks. Internal
;; plumbing shared by the tray and webview platform backends: native menus
;; need positive integer ids (Win32 HMENU uintptr, Gtk gint, NSMenuItem tag
;; NSInteger), while callbacks stay Racket thunks. Internalized behind
;; glaze/private by G3-S2 (docs/api-stability.md) — never public API.

(provide (struct-out id-allocator)
         make-id-allocator
         id-allocator-next!
         id-allocator-register!
         id-allocator-lookup
         id-allocator-clear!)

;; Assigns increasing positive integers as native menu ids and keeps a hash
;; from id -> action so the backend's message handler can dispatch. Backend
;; ids must be positive integers that fit in the native menu id space.
(struct id-allocator (next-box table-sema table) #:transparent)

(define (make-id-allocator)
  (id-allocator (box 1) (make-semaphore 1) (make-hash)))

(define (id-allocator-next! a)
  (define b (id-allocator-next-box a))
  (call-with-semaphore (id-allocator-table-sema a)
                       (lambda ()
                         (begin0 (unbox b)
                           (set-box! b (add1 (unbox b)))))))

(define (id-allocator-register! a action)
  (define id (id-allocator-next! a))
  (call-with-semaphore (id-allocator-table-sema a)
                       (lambda () (hash-set! (id-allocator-table a) id action)))
  id)

(define (id-allocator-lookup a id)
  (call-with-semaphore (id-allocator-table-sema a)
                       (lambda () (hash-ref (id-allocator-table a) id (lambda () #f)))))

(define (id-allocator-clear! a)
  (call-with-semaphore (id-allocator-table-sema a)
                       (lambda ()
                         (hash-clear! (id-allocator-table a))
                         (set-box! (id-allocator-next-box a) 1))))
