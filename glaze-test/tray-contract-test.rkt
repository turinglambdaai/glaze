#lang racket/base

(require rackunit
         glaze/tray/main)

(check-exn exn:fail:contract?
           (lambda () (make-tray #:icon 42 #:tooltip "x" #:menu '())))
(check-exn exn:fail:contract?
           (lambda () (make-tray #:icon #f #:tooltip 42 #:menu '())))
(check-exn exn:fail:contract?
           (lambda () (make-tray #:icon #f #:tooltip "x" #:menu '(bad))))
(check-exn exn:fail:contract?
           (lambda () (make-tray #:icon #f #:tooltip "x" #:menu '()
                                 #:on-event (lambda () #t))))
(check-exn exn:fail:contract?
           (lambda () (tray-close 'not-a-tray)))
(check-exn exn:fail:contract?
           (lambda () (tray-set-tooltip! 'not-a-tray "x")))
