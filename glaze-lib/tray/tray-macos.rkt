#lang racket/base

;; macOS tray backend placeholder.
;;
;; The real implementation will use ffi/unsafe/objc to drive NSStatusBar /
;; NSStatusItem / NSMenu (the defn.io "Remember" project demonstrates the
;; ObjC-FFI pattern is viable). That code only runs on macOS, so this module
;; is only loaded on 'macosx.
;;
;; For now this is a stub that raises on make-tray so the public dispatcher
;; falls back to tray-stub. CI on macOS will exercise the real implementation
;; once it lands; nothing here runs on Windows/Linux hosts.

(require "tray-protocol.rkt"
         "tray-stub.rkt")

(provide make-tray
         set-tooltip!
         set-icon!
         set-menu!
         close
         supported?
         mac:tray?)

(define (mac:tray? x)
  (stub:tray? x))

(define (supported?)
  (and (eq? (system-type 'os) 'macosx) #f)) ; not yet implemented

(define (make-tray #:icon icon-path
                   #:tooltip tooltip
                   #:menu items
                   #:on-event [on-event (lambda (e) (void))])
  (error 'make-tray "macOS tray backend not yet implemented"))

(define (set-tooltip! t tooltip)
  (stub:set-tooltip! t tooltip))
(define (set-icon! t icon-path)
  (stub:set-icon! t icon-path))
(define (set-menu! t items)
  (stub:set-menu! t items))
(define (close t)
  (stub:close t))
