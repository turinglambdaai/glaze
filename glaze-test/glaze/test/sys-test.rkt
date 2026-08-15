#lang racket/base

;; glaze/sys suite: clipboard round-trip (macOS live), single-instance
;; lock semantics, open-path on a temp dir, procedure surface everywhere.

(require rackunit
         racket/file
         glaze/sys/main
         glaze/webview/main)

;; ---- surface (all platforms) ----
(for ([p (in-list (list clipboard-set! clipboard-get notify! open-path
                       reveal-path single-instance? sys-supported?
                       webview-set-title! webview-set-size! webview-set-fullscreen!))])
  (check-true (procedure? p)))

;; ---- single-instance ----
(check-true (single-instance? "glaze-test-app") "first instance wins")
(check-false (single-instance? "glaze-test-app") "second instance loses")
(check-true (single-instance? "glaze-test-other") "different app-id independent")

;; ---- macOS live ----
(when (and (eq? (system-type 'os) 'macosx) (sys-supported?))
  (check-true (clipboard-set! "glaze-sys-test-42") "clipboard set")
  (sleep 0.2)
  (check-equal? (clipboard-get) "glaze-sys-test-42" "clipboard round-trip")
  (check-true (open-path (path->string (find-system-path 'temp-dir))) "open-path runs")
  ;; notify is best-effort; assert it returned a boolean, not an error
  (check-true (boolean? (notify! "glaze test" "body")) "notify returns a boolean"))

;; ---- window controls through the public API (macOS live) ----
(when (and (eq? (system-type 'os) 'macosx) (webview-supported?))
  (define closed? (box #f))
  (define wv (open-window "about:blank"
                          #:title "ctrl-before"
                          #:on-close (lambda () (set-box! closed? #t))))
  (check-true (webview? wv))
  (check-not-exn (lambda () (webview-set-title! wv "ctrl-after")))
  (check-not-exn (lambda () (webview-set-size! wv 640 480)))
  (check-not-exn (lambda () (webview-set-fullscreen! wv #f)))
  (check-not-exn (lambda () (webview-close wv)))
  (sleep 0.2)
  (check-true (unbox closed?) "window closed after controls"))
