#lang racket/base

;; WebView API tests. The macOS backend end-to-end section is gated on
;; 'macosx (mirrors the Windows tray backend tests in main.rkt): the open ->
;; navigate -> close round trip is verifiable even on a headless CI host
;; because none of it waits for page rendering (about:blank), and on-close is
;; delivered synchronously via performClose:.

(require rackunit
         racket/file
         glaze/server
         glaze/webview/main)

;; ---- Public API surface (all platforms) ----
(check-equal? (procedure? open-window) #t "open-window is a procedure")
(check-equal? (procedure? open-webview) #t "open-webview is a procedure")
(check-equal? (procedure? webview-supported?) #t "webview-supported? is a procedure")
(check-equal? (procedure? webview-last-error) #t "webview-last-error is a procedure")
(check-equal? (procedure? webview-install-guidance) #t "webview-install-guidance is a procedure")
(check-equal? (procedure? webview-diagnostic) #t "webview-diagnostic is a procedure")
(check-true (positive? (string-length (webview-install-guidance)))
            "platform install guidance is non-empty")
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
  (check-false (webview-capture! wv) "capture after close returns #f")

  ;; ---- multi-window: one shared pump services every open window ----
  ;; (previously one pump thread per window, all contending for the same
  ;; main run loop). Two webviews load distinct pages; both must commit,
  ;; the survivor must stay serviced after the first closes, and the pump
  ;; must exit when the last window closes.
  (define mv-dir (make-temporary-file "glaze-mv-~a" 'directory))
  (make-directory* (build-path mv-dir "a"))
  (make-directory* (build-path mv-dir "b"))
  (make-directory* (build-path mv-dir "c"))
  (call-with-output-file (build-path mv-dir "a" "index.html")
    (lambda (o) (display "<html><head><title>alpha</title></head></html>" o)))
  (call-with-output-file (build-path mv-dir "b" "index.html")
    (lambda (o) (display "<html><head><title>beta</title></head></html>" o)))
  (call-with-output-file (build-path mv-dir "c" "index.html")
    (lambda (o) (display "<html><head><title>gamma</title></head></html>" o)))
  (define-values (mv-port mv-stop)
    (start-server #:port 18993 #:public-dir mv-dir))
  (define mod-title (dynamic-require 'glaze/webview/webview-macos 'title))
  (define closed-a? (box #f))
  (define closed-b? (box #f))
  (define wa
    (mod-open (format "http://127.0.0.1:~a/a/index.html" mv-port)
              #:title "multi-a" #:on-close (lambda () (set-box! closed-a? #t))))
  (define wb
    (mod-open (format "http://127.0.0.1:~a/b/index.html" mv-port)
              #:title "multi-b" #:on-close (lambda () (set-box! closed-b? #t))))
  ;; both pages commit through the one pump (deadline: slow CI hosts)
  (define both-loaded?
    (let dl ([deadline (+ (current-inexact-milliseconds) 10000)])
      (cond
        [(and (equal? (mod-title wa) "alpha") (equal? (mod-title wb) "beta")) #t]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else (sleep 0.1) (dl deadline)])))
  (check-true both-loaded? "shared pump services both windows")
  (mod-close wa)
  (sleep 0.2)
  (check-true (unbox closed-a?) "first window on-close fired")
  ;; survivor stays serviced after the first window closed: a fresh
  ;; navigation must still commit (title reads alone would not prove the
  ;; runloop is being pumped, since they bypass it)
  (mod-navigate wb (format "http://127.0.0.1:~a/c/index.html" mv-port))
  (define survivor-serviced?
    (let dl ([deadline (+ (current-inexact-milliseconds) 10000)])
      (cond
        [(equal? (mod-title wb) "gamma") #t]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else (sleep 0.1) (dl deadline)])))
  (check-true survivor-serviced? "survivor still serviced after first close")
  (mod-close wb)
  (sleep 0.2)
  (check-true (unbox closed-b?) "second window on-close fired")
  ;; the shared pump exits once no window remains
  (check-not-false (sync/timeout 3 (thread-dead-evt (mod-thread wb)))
                   "shared pump exits after the last window closes")
  (mv-stop)
  (delete-directory/files mv-dir))
