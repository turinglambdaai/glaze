#lang racket/base

;; Platform-agnostic tray protocol: menu-item data structure and an id-allocator
;; for mapping native menu ids back to Racket callbacks. Platform backends
;; translate these structs into native menus (Win32 TrackPopupMenu, NSMenu,
;; GtkMenu) and invoke the matching callback when a menu id fires.

(require racket/contract)

(provide (struct-out menu-item)
         make-menu-item
         menu-separator
         menu-item?
         menu-separator?
         make-id-allocator
         id-allocator-next!
         id-allocator-register!
         id-allocator-lookup
         id-allocator-clear!)

;; A menu item. Separators have label #f and id #f. Normal items carry a label,
;; a stable id (string, user-provided for stable dispatch) and an action thunk.
;; `enabled?` and `checked?` are hints the backend may honor when supported.
(struct menu-item (label id action enabled? checked?) #:transparent)

(define (make-menu-item label
                        #:id [id label]
                        #:action [action (lambda () (void))]
                        #:enabled? [enabled? #t]
                        #:checked? [checked? #f])
  (menu-item label id action enabled? checked?))

(define (menu-separator)
  (menu-item #f #f (lambda () (void)) #t #f))

(define (menu-separator? mi)
  (and (menu-item? mi) (not (menu-item-label mi))))

;; Id allocator: assigns increasing positive integers as native menu ids and
;; keeps a hash from id -> action so the backend's message handler can dispatch.
;; Backend ids must be positive integers that fit in the native menu id space
;; (Win32 HMENU uses uintptr; Gtk uses gint; NSMenuItem uses tag NSInteger).
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
