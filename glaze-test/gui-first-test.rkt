#lang racket/base

;; Regression tests for Glaze's GUI-first contract. These deliberately avoid
;; opening a real window so they run on every CI host; the platform e2e tests
;; continue to cover successful native-window startup.

(require rackunit
         racket/string
         glaze/app
         glaze/webview/main)

(define-values (_open-required open-allowed) (procedure-keywords open-window))
(define-values (_wv-required wv-allowed) (procedure-keywords open-webview))
(define-values (_app-required app-allowed) (procedure-keywords run-app))

;; Browser fallback used to be a keyword on all three entry points. Keeping
;; this assertion makes it hard to accidentally reintroduce the escape hatch.
(check-true (list? open-allowed))
(check-true (list? wv-allowed))
(check-true (list? app-allowed))
(check-false (member '#:fallback-browser? open-allowed))
(check-false (member '#:fallback-browser? wv-allowed))
(check-false (member '#:fallback-browser? app-allowed))

;; A missing backend must produce useful remediation text instead of sending
;; the user to a browser. The exact package differs by platform.
(define guidance (webview-install-guidance))
(check-true (string? guidance))
(check-true (> (string-length guidance) 20))
(check-false (string-contains? (string-downcase guidance) "fallback"))

(case (system-type 'os)
  [(windows)
   (check-true (string-contains? guidance "WebView2 Runtime"))
   (check-true (string-contains? guidance "developer.microsoft.com"))]
  [(unix)
   (check-true (string-contains? guidance "WebKitGTK"))
   (check-true (string-contains? guidance "apt install"))]
  [(macosx)
   (check-true (string-contains? guidance "WKWebView"))]
  [else (void)])

(define diagnostic (webview-diagnostic "test backend failure"))
(check-true (string-contains? diagnostic "test backend failure"))
(check-true (string-contains? diagnostic guidance))
