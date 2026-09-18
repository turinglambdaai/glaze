#lang racket/base

(require rackunit
         glaze/tray/tray-protocol)

(check-exn exn:fail:contract?
           (lambda () (make-menu-item 42)))
(check-exn exn:fail:contract?
           (lambda () (make-menu-item "Open" #:id 'open)))
(check-exn exn:fail:contract?
           (lambda () (make-menu-item "Open" #:action (lambda (x) x))))
(check-exn exn:fail:contract?
           (lambda () (make-menu-item "Open" #:enabled? 'yes)))
(check-exn exn:fail:contract?
           (lambda () (make-menu-item "Open" #:accel 42)))
(check-exn exn:fail:contract?
           (lambda () (make-menu 42 '())))
(check-exn exn:fail:contract?
           (lambda () (make-menu "File" '(not-an-item))))

(define alloc (make-id-allocator))
(check-exn exn:fail:contract?
           (lambda () (id-allocator-register! alloc (lambda (x) x))))
(check-exn exn:fail:contract?
           (lambda () (id-allocator-lookup alloc 0)))
