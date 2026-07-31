#lang racket/base

;; Linux tray backend placeholder.
;;
;; The real implementation will use ffi/unsafe to bind libayatana-appindicator
;; (with a libgtk-3 menu), detecting the libraries at runtime and falling back
;; to the stub (with a stderr warning) when they are missing. That code only
;; runs on 'unix, so this module is only loaded there.
;;
;; For now this is a stub that raises on make-tray so the public dispatcher
;; falls back to tray-stub. CI on Linux (with the appindicator dev packages
;; installed) will exercise the real implementation once it lands.

(require "tray-protocol.rkt"
         "tray-stub.rkt")

(provide make-tray
         set-tooltip!
         set-icon!
         set-menu!
         close
         supported?
         lin:tray?)

(define (lin:tray? x)
  (stub:tray? x))

(define (supported?)
  (and (eq? (system-type 'os) 'unix) #f)) ; not yet implemented

(define (make-tray #:icon icon-path
                   #:tooltip tooltip
                   #:menu items
                   #:on-event [on-event (lambda (e) (void))])
  (error 'make-tray "Linux tray backend not yet implemented"))

(define (set-tooltip! t tooltip)
  (stub:set-tooltip! t tooltip))
(define (set-icon! t icon-path)
  (stub:set-icon! t icon-path))
(define (set-menu! t items)
  (stub:set-menu! t items))
(define (close t)
  (stub:close t))
