#lang racket/base

;; Stub tray backend: used when the platform is unsupported or the native
;; libraries required by a real backend are missing. Every operation is a
;; no-op so the rest of the app keeps working without a tray.

(provide stub:make-tray
         stub:tray?
         stub:set-tooltip!
         stub:set-icon!
         stub:set-menu!
         stub:close
         stub-supported?)

;; A tray handle is just a box around a boolean "open?" flag, so callers and
;; tests can distinguish an open tray from a closed one without any native
;; resources.
(struct stub:tray (open?-box) #:mutable)

(define (stub-supported?)
  ;; The stub is always "available" — it just does nothing. Platforms pick a
  ;; real backend when native support is present and fall back to this.
  #t)

(define (stub:make-tray #:icon icon-path
                        #:tooltip tooltip
                        #:menu items
                        #:on-event [on-event (lambda (e) (void))])
  (stub:tray (box #t)))

(define (stub:set-tooltip! t tooltip)
  (void))
(define (stub:set-icon! t icon-path)
  (void))
(define (stub:set-menu! t items)
  (void))

(define (stub:close t)
  (set-box! (stub:tray-open?-box t) #f))

(define (stub:open? t)
  (unbox (stub:tray-open?-box t)))
