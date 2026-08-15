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
         capture!)

(define (supported?)
  #f)

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:devtools? [devtools? #f]
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
