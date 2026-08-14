#lang racket/base

;; WebView API tests. The macOS backend end-to-end section is gated on
;; 'macosx (mirrors the Windows tray backend tests in main.rkt): the open ->
;; navigate -> close round trip is verifiable even on a headless CI host
;; because none of it waits for page rendering (about:blank), and on-close is
;; delivered synchronously via performClose:.

(require rackunit
         racket/file
         glaze/webview/main)

;; ---- Public API surface (all platforms) ----
(check-equal? (procedure? open-window) #t "open-window is a procedure")
(check-equal? (procedure? open-webview) #t "open-webview is a procedure")
(check-equal? (procedure? webview-supported?) #t "webview-supported? is a procedure")
(check-equal? (procedure? webview-navigate) #t "webview-navigate is a procedure")
(check-equal? (procedure? webview-close) #t "webview-close is a procedure")
(check-equal? (procedure? webview-title) #t "webview-title is a procedure")
(check-equal? (procedure? webview-url) #t "webview-url is a procedure")
(check-equal? (procedure? webview-capture!) #t "webview-capture! is a procedure")

;; ---- macOS WebView backend end-to-end (only on 'macosx) ----
(when (eq? (system-type 'os) 'macosx)
  (define mod-supported? (dynamic-require 'glaze/webview/webview-macos 'supported?))
  (define mod-open (dynamic-require 'glaze/webview/webview-macos 'open-webview))
  (define mod-mac:webview? (dynamic-require 'glaze/webview/webview-macos 'mac:webview?))
  (define mod-thread (dynamic-require 'glaze/webview/webview-macos 'mac:webview-thread))
  (define mod-navigate (dynamic-require 'glaze/webview/webview-macos 'navigate))
  (define mod-close (dynamic-require 'glaze/webview/webview-macos 'close))
  (check-true (mod-supported?) "macOS webview backend reports supported")
  (check-true (webview-supported?) "public webview-supported? agrees on macOS")

  ;; Direct backend handle.
  (define closed? (box #f))
  (define bw (mod-open "about:blank"
                       #:title "glaze test"
                       #:width 320
                       #:height 240
                       #:on-close (lambda () (set-box! closed? #t))))
  (check-true (mod-mac:webview? bw) "direct backend returns mac:webview?")
  (check-not-exn (lambda () (mod-navigate bw "about:blank")) "backend navigate does not raise")
  (check-not-exn (lambda () (mod-close bw)) "backend close does not raise")
  (sleep 0.2)
  (check-true (unbox closed?) "on-close callback fired")
  (check-not-false (sync/timeout 3 (thread-dead-evt (mod-thread bw)))
                   "pump thread exits after close")

  ;; Public dispatcher path.
  (define closed2? (box #f))
  (define wv (open-window "about:blank"
                          #:title "glaze public"
                          #:on-close (lambda () (set-box! closed2? #t))))
  (check-true (webview? wv) "open-window returns a webview? on macOS")
  (check-equal? (webview-backend wv) 'macos "backend tag is macos")
  (check-not-exn (lambda () (webview-navigate wv "about:blank")) "navigate does not raise")
  ;; Verification APIs: url commits once the runloop services the load; give
  ;; it a bounded wait rather than a fixed sleep so slow CI hosts pass too.
  (define url-ok?
    (let deadline-loop ([deadline (+ (current-inexact-milliseconds) 10000)])
      (cond
        [(equal? (webview-url wv) "about:blank") #t]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else (sleep 0.1) (deadline-loop deadline)])))
  (check-true url-ok? "webview-url reports the committed page")
  (define tmp-png (make-temporary-file "glaze-test-cap-~a.png"))
  ;; CGWindowListCreateImage returns NULL until the window has actually been
  ;; composited to the screen, so retry briefly instead of asserting at an
  ;; arbitrary point in time.
  (define shot
    (let retry ([deadline (+ (current-inexact-milliseconds) 5000)])
      (define s (webview-capture! wv tmp-png))
      (cond
        [(and s (>= (file-size s) 1000)) s]
        [(> (current-inexact-milliseconds) deadline) s]
        [else (sleep 0.2) (retry deadline)])))
  (check-not-false shot "webview-capture! returns a path")
  (check-true (and shot (>= (file-size shot) 1000)) "capture PNG is non-trivial")
  (when (and shot (file-exists? shot)) (delete-file shot))
  (check-not-exn (lambda () (webview-close wv)) "close does not raise")
  (sleep 0.2)
  (check-true (unbox closed2?) "public open-window on-close fired")
  (check-false (webview-capture! wv) "capture after close returns #f"))
