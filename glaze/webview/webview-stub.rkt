#lang racket/base

;; Stub WebView backend: used when the platform is unsupported or the native
;; libraries required by a real backend are missing. open-webview returns #f
;; so the public dispatcher (and callers) can fall back to the system browser.

(provide open-webview
         supported?
         close
         navigate
         title
         url
         capture!
         set-title!
         set-size!
         set-fullscreen!
         focus!
         set-menu!
         closed?)

(define (supported?)
  #f)

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:devtools? [devtools? #f]
                      #:background-active? [background-active? #f]
                      #:on-close [on-close (lambda () (void))])
  #f)

(define (close h)
  (void))
(define (navigate h url)
  (void))
(define (title h)
  #f)
(define (url h)
  #f)
(define (capture! h [dest #f])
  #f)

(define (set-title! h t) (void))
(define (set-size! h w height) (void))
(define (set-fullscreen! h on?) (void))

(define (focus! h) (void))

;; Menu bar and liveness: the stub has no window — everything is closed,
;; menus are a no-op.
(define (set-menu! h menus) (void))
(define (closed? h) #t)
