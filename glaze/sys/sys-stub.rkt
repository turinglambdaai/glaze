#lang racket/base

(provide supported? clipboard-set! clipboard-get notify! open-path reveal-path)

(define (supported?) #f)
(define (clipboard-set! text) #f)
(define (clipboard-get) "")
(define (notify! title body subtitle) #f)
(define (open-path p) #f)
(define (reveal-path p) #f)
