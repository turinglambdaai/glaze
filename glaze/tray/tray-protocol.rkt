#lang racket/base

;; Platform-agnostic menu/tray protocol. Platform backends translate these
;; values into Win32, AppKit, or GTK menu objects; malformed values therefore
;; need to be rejected here, before they reach native FFI.

(provide (struct-out menu-item)
         make-menu-item
         menu-separator
         menu-item?
         menu-separator?
         (struct-out menu)
         make-menu
         make-id-allocator
         id-allocator-next!
         id-allocator-register!
         id-allocator-lookup
         id-allocator-clear!)

(struct menu-item (label id action enabled? checked? accel) #:transparent)

(define (make-menu-item label
                        #:id [id label]
                        #:action [action (lambda () (void))]
                        #:enabled? [enabled? #t]
                        #:checked? [checked? #f]
                        #:accel [accel #f])
  (unless (string? label)
    (raise-argument-error 'make-menu-item "string?" label))
  (unless (string? id)
    (raise-argument-error 'make-menu-item "string?" id))
  (unless (and (procedure? action) (procedure-arity-includes? action 0))
    (raise-argument-error 'make-menu-item "procedure accepting zero arguments" action))
  (unless (boolean? enabled?)
    (raise-argument-error 'make-menu-item "boolean?" enabled?))
  (unless (boolean? checked?)
    (raise-argument-error 'make-menu-item "boolean?" checked?))
  (unless (or (not accel) (string? accel))
    (raise-argument-error 'make-menu-item "(or/c #f string?)" accel))
  (menu-item label id action enabled? checked? accel))

(define (menu-separator)
  (menu-item #f #f (lambda () (void)) #t #f #f))

(define (menu-separator? mi)
  (and (menu-item? mi) (not (menu-item-label mi))))

(struct menu (title items) #:transparent)

(define (make-menu title items)
  (unless (string? title)
    (raise-argument-error 'make-menu "string?" title))
  (unless (and (list? items) (andmap menu-item? items))
    (raise-argument-error 'make-menu "(listof menu-item?)" items))
  (menu title items))

(struct id-allocator (next-box table-sema table) #:transparent)

(define (make-id-allocator)
  (id-allocator (box 1) (make-semaphore 1) (make-hash)))

(define (check-allocator who a)
  (unless (id-allocator? a)
    (raise-argument-error who "id-allocator?" a)))

(define (id-allocator-next! a)
  (check-allocator 'id-allocator-next! a)
  (define b (id-allocator-next-box a))
  (call-with-semaphore
   (id-allocator-table-sema a)
   (lambda ()
     (begin0 (unbox b)
       (set-box! b (add1 (unbox b)))))))

(define (id-allocator-register! a action)
  (check-allocator 'id-allocator-register! a)
  (unless (and (procedure? action) (procedure-arity-includes? action 0))
    (raise-argument-error 'id-allocator-register!
                          "procedure accepting zero arguments"
                          action))
  (define id (id-allocator-next! a))
  (call-with-semaphore
   (id-allocator-table-sema a)
   (lambda () (hash-set! (id-allocator-table a) id action)))
  id)

(define (id-allocator-lookup a id)
  (check-allocator 'id-allocator-lookup a)
  (unless (exact-positive-integer? id)
    (raise-argument-error 'id-allocator-lookup "exact-positive-integer?" id))
  (call-with-semaphore
   (id-allocator-table-sema a)
   (lambda () (hash-ref (id-allocator-table a) id (lambda () #f)))))

(define (id-allocator-clear! a)
  (check-allocator 'id-allocator-clear! a)
  (call-with-semaphore
   (id-allocator-table-sema a)
   (lambda ()
     (hash-clear! (id-allocator-table a))
     (set-box! (id-allocator-next-box a) 1))))
