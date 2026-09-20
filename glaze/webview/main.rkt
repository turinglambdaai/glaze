#lang racket/base

;; Public WebView API. Opens a native OS window with an embedded WebView
;; control pointing at a URL (typically the local HTTP server Glaze started).
;; Dispatches to a platform-specific backend based on (system-type 'os):
;;   - 'windows  -> webview-windows.rkt  (Win32 window + WebView2 via COM FFI)
;;   - 'macosx   -> webview-macos.rkt    (NSWindow + WKWebView via objc FFI)
;;   - 'unix     -> webview-linux.rkt    (GtkWindow + WebKitGTK via FFI)
;;
;; Glaze is a desktop GUI framework: native WebView startup is part of the
;; application contract. There is deliberately no browser fallback. If a
;; backend or runtime dependency is unavailable, startup fails with actionable
;; platform-specific installation guidance.

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

(require (only-in "../tray/tray-protocol.rkt" menu?))

;; A webview handle wraps the backend-specific handle + the backend tag.
(struct webview (backend handle) #:transparent)

;; Keep the most recent native-backend failure so probes and higher-level
;; callers can report the real cause rather than masking it.
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

;; Every successfully opened window, weakly held: closed + collected windows
;; disappear from all-webviews on their own.
(define open-registry (make-weak-hasheq))

;; Pick the backend module path for the current OS.
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

;; Non-throwing capability probe. A failed probe records the reason when one
;; is available; actual startup through open-window/open-webview is fail-fast.
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

;; open-window: high-level entry. Native GUI is mandatory. If the platform
;; backend cannot start, the call raises with installation/repair guidance.
(define (open-window url
                     #:title [title "Glaze"]
                     #:width [width 1024]
                     #:height [height 768]
                     #:devtools? [devtools? #f]
                     #:on-close [on-close (lambda () (void))])
  (open-webview url
                #:title title
                #:width width
                #:height height
                #:devtools? devtools?
                #:on-close on-close))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:devtools? [devtools? #f]
                      #:on-close [on-close (lambda () (void))])
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
        #:on-close on-close)))
  (cond
    [h
     (define wv (webview (detected-backend) h))
     (hash-set! open-registry wv #t)
     wv]
    [else
     (unless (webview-last-error)
       (remember-webview-error! "the native backend returned unavailable"))
     (raise-user-error 'open-webview (webview-diagnostic))]))

(define (detected-backend)
  (case (system-type 'os)
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]
    [else 'stub]))

(define (webview-close wv)
  ((ref 'close) (webview-handle wv)))

(define (webview-navigate wv url)
  ((ref 'navigate) (webview-handle wv) url))

;; ---- verification APIs ----
;; Observe webview state programmatically — the point is that callers (and
;; agents developing Glaze apps) can assert on what the UI is showing without
;; a human at the screen. All degrade to #f where a backend cannot provide
;; the value yet.

;; Current page title once the first navigation has committed, else #f.
(define (webview-title wv)
  ((ref 'title) (webview-handle wv)))

;; Current page URL once the first navigation has committed, else #f.
(define (webview-url wv)
  ((ref 'url) (webview-handle wv)))

;; Captures the window contents to a PNG. dest defaults to a fresh temp
;; file. Returns the path, or #f when the backend/window cannot be captured.
(define (webview-capture! wv [dest #f])
  ((ref 'capture!) (webview-handle wv) dest))

;; ---- window controls ----
(define (webview-set-title! wv t) ((ref 'set-title!) (webview-handle wv) t))
(define (webview-set-size! wv width height)
  ((ref 'set-size!) (webview-handle wv) width height))
(define (webview-set-fullscreen! wv on?)
  ((ref 'set-fullscreen!) (webview-handle wv) on?))

(define (webview-focus! wv) ((ref 'focus!) (webview-handle wv)))

;; ---- menu bar ----
;; Replace the app's custom menus with `menus` — a list of menu? values
;; (glaze/tray/tray-protocol: make-menu + make-menu-item / menu-separator,
;; with #:action thunks and optional #:accel like "Cmd+O"). Real keystroke
;; accelerators on macOS; display-only hints on Windows/Linux (v1).
(define (webview-set-menu! wv menus)
  ((ref 'set-menu!) (webview-handle wv) menus))

;; ---- multi-window ----

;; True once the window is closed (either webview-close or the OS chrome).
(define (webview-closed? wv)
  ((ref 'closed?) (webview-handle wv)))

;; All windows this process opened that have not been garbage collected.
;; Closed-but-uncollected handles report webview-closed? = #t.
(define (all-webviews)
  (for/list ([(wv _) (in-hash open-registry)]) wv))

;; Close every open window (delivers #:on-close for each).
(define (close-all-webviews!)
  (for ([wv (in-list (all-webviews))] #:unless (webview-closed? wv))
    (webview-close wv)))

;; Block until every open window is closed (OS chrome closes included), or
;; until timeout-secs elapse. Returns #t when all closed, #f on timeout.
(define (wait-for-webviews [timeout-secs #f])
  (define deadline
    (and timeout-secs (+ (current-inexact-milliseconds) (* timeout-secs 1000))))
  (let loop ()
    (define open (for/list ([wv (in-list (all-webviews))]
                            #:unless (webview-closed? wv))
                   wv))
    (cond
      [(null? open) #t]
      [(and deadline (>= (current-inexact-milliseconds) deadline)) #f]
      [else (sleep 0.05) (loop)])))
