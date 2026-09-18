#lang racket/base

(require rackunit
         glaze/sys/main)

(check-exn exn:fail:contract?
           (lambda () (clipboard-set! 42)))
(check-exn exn:fail:contract?
           (lambda () (notify! 42)))
(check-exn exn:fail:contract?
           (lambda () (notify! "title" 42)))
(check-exn exn:fail:contract?
           (lambda () (notify! "title" "body" #:subtitle 42)))
(check-exn exn:fail:contract?
           (lambda () (open-path 42)))
(check-exn exn:fail:contract?
           (lambda () (reveal-path 42)))
(check-exn exn:fail:contract?
           (lambda () (single-instance? "")))
