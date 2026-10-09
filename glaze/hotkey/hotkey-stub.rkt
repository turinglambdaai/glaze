#lang racket/base

;; Stub hotkey backend for platforms without a native implementation.

(provide supported?
         register!
         unregister!
         unregister-all!
         registered?)

(define (supported?)
  #f)
(define (register! hk thunk)
  #f)
(define (unregister! hk)
  #f)
(define (unregister-all!)
  #f)
(define (registered? hk)
  #f)
