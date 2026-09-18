#lang racket/base

(require rackunit
         glaze/webview/main)

;; These checks must fail before any platform backend is loaded, so callers get
;; the same public contract on Windows, macOS, Linux, and headless hosts.
(check-exn exn:fail:contract?
           (lambda () (open-window 42)))
(check-exn exn:fail:contract?
           (lambda () (open-window "about:blank" #:title 42)))
(check-exn exn:fail:contract?
           (lambda () (open-window "about:blank" #:width 0)))
(check-exn exn:fail:contract?
           (lambda () (open-window "about:blank" #:height -1)))
(check-exn exn:fail:contract?
           (lambda () (open-window "about:blank" #:devtools? 'yes)))
(check-exn exn:fail:contract?
           (lambda () (open-window "about:blank" #:background-active? 'yes)))
(check-exn exn:fail:contract?
           (lambda () (open-window "about:blank" #:on-close 42)))
(check-exn exn:fail:contract?
           (lambda () (open-window "about:blank" #:fallback-browser? 'yes)))

(check-exn exn:fail:contract?
           (lambda () (webview-close 'not-a-webview)))
(check-exn exn:fail:contract?
           (lambda () (webview-navigate 'not-a-webview "about:blank")))
(check-exn exn:fail:contract?
           (lambda () (webview-title 'not-a-webview)))
(check-exn exn:fail:contract?
           (lambda () (webview-set-size! 'not-a-webview 640 480)))
(check-exn exn:fail:contract?
           (lambda () (wait-for-webviews -1)))
