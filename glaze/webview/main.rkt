#lang racket/base

;; Public WebView API. Glaze is GUI-first: a native WebView is mandatory and
;; startup fails with platform-specific guidance when its backend is missing.
;; Platform-specific FFI stays behind this dispatcher.

(provide open-window
         open-webview
         webview-supported?
         webview-last-error
         webview-install-guidance
         webview-diagnostic
         webview?
         webview-backend
         webview-handle
         webview-close
         webview-navigate
         webview-title
         webview-url
         webview-capture!
         webview-set-title!
         webview-set-size!
         webview-set-fullscreen!
         webview-focus!
         webview-set-menu!
         webview-closed?
         all-webviews
         close-all-webviews!
         wait-for-webviews)

(require "startup-feedback.rkt"
         (only-in "../tray/tray-protocol.rkt" menu?))

(struct webview (backend handle) #:transparent)

(define last-webview-error-box (box #f))

(define (webview-last-error)
  (unbox last-webview-error-box))

(define (remember-webview-error! e)
  (set-box! last-webview-error-box e))

(define (clear-webview-error!)
  (set-box! last-webview-error-box #f))

(define (webview-install-guidance)
  (case (system-type 'os)
    [(windows)
     (string-append
      "Windows requires Microsoft Edge WebView2 Runtime (Evergreen).\n"
      "Install or repair it, then start Glaze again:\n"
      "  winget install --id Microsoft.EdgeWebView2Runtime -e\n"
      "Official download (Evergreen Bootstrapper / Standalone Installer):\n"
      "  https://developer.microsoft.com/microsoft-edge/webview2/#download-section\n"
      "Glaze already ships WebView2Loader.dll. If the Runtime is installed, "
      "verify that the Glaze package and Racket architecture match your Windows architecture.")]
    [(unix)
     (string-append
      "Linux requires GTK 3 and WebKitGTK at runtime. Install the packages, then start Glaze again:\n"
      "  Debian/Ubuntu: sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0\n"
      "  Fedora:        sudo dnf install gtk3 webkit2gtk4.1\n"
      "  Arch:          sudo pacman -S gtk3 webkit2gtk-4.1\n"
      "Glaze must also run inside a graphical desktop session (or Xvfb in CI).")]
    [(macosx)
     (string-append
      "WKWebView is built into macOS and normally requires no separate download.\n"
      "Run Glaze from a logged-in graphical session. If startup still fails, "
      "report the backend error above together with your macOS and Racket versions.")]
    [else
     "This operating system has no native WebView backend in Glaze."]))

(define (webview-error->message e)
  (cond
    [(exn? e) (exn-message e)]
    [(string? e) e]
    [e (format "~a" e)]
    [else "the native backend reported that it is unavailable"]))

(define (webview-diagnostic [e (webview-last-error)])
  (string-append
   "Native WebView could not start: " (webview-error->message e) "\n\n"
   (webview-install-guidance)))

(define open-registry (make-weak-hasheq))

(define (backend-module-path)
  (case (system-type 'os)
    [(windows) 'glaze/webview/webview-windows]
    [(macosx) 'glaze/webview/webview-macos]
    [(unix) 'glaze/webview/webview-linux]
    [else 'glaze/webview/webview-stub]))

(define backend-procs #f)

(define (load-backend!)
  (unless backend-procs
    (set! backend-procs (make-hash))
    (define mod (backend-module-path))
    (for ([name (in-list '(open-webview supported? close navigate title url capture!
                             set-title! set-size! set-fullscreen! focus!
                             set-menu! closed?))])
      (hash-set! backend-procs name (dynamic-require mod name))))
  backend-procs)

(define (ref name)
  (hash-ref (load-backend!) name))

(define (webview-supported?)
  (clear-webview-error!)
  (with-handlers ([exn:fail? (lambda (e)
                               (remember-webview-error! e)
                               #f)])
    (define supported? ((ref 'supported?)))
    (unless supported?
      (remember-webview-error!
       "the platform backend is present but its runtime dependencies are not available"))
    supported?))

(define (check-open-args who url title width height devtools? background-active?
                         on-close)
  (unless (string? url)
    (raise-argument-error who "string?" url))
  (unless (string? title)
    (raise-argument-error who "string?" title))
  (unless (exact-positive-integer? width)
    (raise-argument-error who "exact-positive-integer?" width))
  (unless (exact-positive-integer? height)
    (raise-argument-error who "exact-positive-integer?" height))
  (unless (boolean? devtools?)
    (raise-argument-error who "boolean?" devtools?))
  (unless (boolean? background-active?)
    (raise-argument-error who "boolean?" background-active?))
  (unless (procedure? on-close)
    (raise-argument-error who "procedure?" on-close)))

(define (check-webview who wv)
  (unless (webview? wv)
    (raise-argument-error who "webview?" wv)))

(define (open-window url
                     #:title [title "Glaze"]
                     #:width [width 1024]
                     #:height [height 768]
                     #:devtools? [devtools? #f]
                     #:background-active? [background-active? #f]
                     #:on-close [on-close (lambda () (void))])
  (check-open-args 'open-window url title width height devtools?
                   background-active? on-close)
  (open-webview url
                #:title title
                #:width width
                #:height height
                #:devtools? devtools?
                #:background-active? background-active?
                #:on-close on-close))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:devtools? [devtools? #f]
                      #:background-active? [background-active? #f]
                      #:on-close [on-close (lambda () (void))])
  (check-open-args 'open-webview url title width height devtools?
                   background-active? on-close)
  (clear-webview-error!)
  (define h
    (with-handlers ([exn:fail? (lambda (e)
                                 (remember-webview-error! e)
                                 #f)])
      ((ref 'open-webview) url
        #:title title
        #:width width
        #:height height
        #:devtools? devtools?
        #:background-active? background-active?
        #:on-close on-close)))
  (cond
    [h
     (define wv (webview (detected-backend) h))
     (hash-set! open-registry wv #t)
     wv]
    [else
     (unless (webview-last-error)
       (remember-webview-error! "the native backend returned unavailable"))
     (define diagnostic (webview-diagnostic))
     (show-webview-startup-error! diagnostic)
     (raise-user-error 'open-webview diagnostic)]))

(define (detected-backend)
  (case (system-type 'os)
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]
    [else 'stub]))

(define (webview-close wv)
  (check-webview 'webview-close wv)
  ((ref 'close) (webview-handle wv)))

(define (webview-navigate wv url)
  (check-webview 'webview-navigate wv)
  (unless (string? url)
    (raise-argument-error 'webview-navigate "string?" url))
  ((ref 'navigate) (webview-handle wv) url))

(define (webview-title wv)
  (check-webview 'webview-title wv)
  ((ref 'title) (webview-handle wv)))

(define (webview-url wv)
  (check-webview 'webview-url wv)
  ((ref 'url) (webview-handle wv)))

(define (webview-capture! wv [dest #f])
  (check-webview 'webview-capture! wv)
  (unless (or (not dest) (path? dest) (string? dest))
    (raise-argument-error 'webview-capture! "(or/c #f path? string?)" dest))
  ((ref 'capture!) (webview-handle wv) dest))

(define (webview-set-title! wv t)
  (check-webview 'webview-set-title! wv)
  (unless (string? t)
    (raise-argument-error 'webview-set-title! "string?" t))
  ((ref 'set-title!) (webview-handle wv) t))

(define (webview-set-size! wv width height)
  (check-webview 'webview-set-size! wv)
  (unless (exact-positive-integer? width)
    (raise-argument-error 'webview-set-size! "exact-positive-integer?" width))
  (unless (exact-positive-integer? height)
    (raise-argument-error 'webview-set-size! "exact-positive-integer?" height))
  ((ref 'set-size!) (webview-handle wv) width height))

(define (webview-set-fullscreen! wv on?)
  (check-webview 'webview-set-fullscreen! wv)
  (unless (boolean? on?)
    (raise-argument-error 'webview-set-fullscreen! "boolean?" on?))
  ((ref 'set-fullscreen!) (webview-handle wv) on?))

(define (webview-focus! wv)
  (check-webview 'webview-focus! wv)
  ((ref 'focus!) (webview-handle wv)))

(define (webview-set-menu! wv menus)
  (check-webview 'webview-set-menu! wv)
  (unless (and (list? menus) (andmap menu? menus))
    (raise-argument-error 'webview-set-menu! "(listof menu?)" menus))
  ((ref 'set-menu!) (webview-handle wv) menus))

(define (webview-closed? wv)
  (check-webview 'webview-closed? wv)
  ((ref 'closed?) (webview-handle wv)))

(define (all-webviews)
  (for/list ([(wv _) (in-hash open-registry)]) wv))

(define (close-all-webviews!)
  (for ([wv (in-list (all-webviews))] #:unless (webview-closed? wv))
    (webview-close wv)))

(define (wait-for-webviews [timeout-secs #f])
  (unless (or (not timeout-secs)
              (and (real? timeout-secs) (>= timeout-secs 0)))
    (raise-argument-error 'wait-for-webviews "(or/c #f nonnegative-real?)"
                          timeout-secs))
  (define deadline
    (and timeout-secs (+ (current-inexact-milliseconds) (* timeout-secs 1000))))
  (let loop ()
    (define open
      (for/list ([wv (in-list (all-webviews))]
                 #:unless (webview-closed? wv))
        wv))
    (cond
      [(null? open) #t]
      [(and deadline (>= (current-inexact-milliseconds) deadline)) #f]
      [else (sleep 0.05) (loop)])))
