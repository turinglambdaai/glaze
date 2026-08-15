#lang racket/base

;; Public WebView API (Phase 3). Opens a native OS window with an embedded
;; WebView control pointing at a URL (typically the local HTTP server Glaze
;; started). Dispatches to a platform-specific backend based on
;; (system-type 'os):
;;   - 'windows  -> webview-windows.rkt  (Win32 window + WebView2 via COM FFI)
;;   - 'macosx   -> webview-macos.rkt    (NSWindow + WKWebView via objc FFI)
;;   - 'unix     -> webview-linux.rkt    (GtkWindow + WebKitGTK via FFI)
;;
;; Every backend exports the SAME procedure names (open-webview,
;; webview-supported?, close-webview, webview-navigate) and performs its own
;; platform/library gating. If a backend is unavailable, open-webview returns
;; #f so callers can fall back to opening the system browser (Phase 1/2
;; behavior).

(provide open-window
         open-webview
         webview-supported?
         webview?
         webview-backend
         webview-handle
         webview-close
         webview-navigate
         webview-title
         webview-url
         webview-capture!)

(require (only-in "../browser.rkt" open-browser))

;; A webview handle wraps the backend-specific handle + the backend tag.
(struct webview (backend handle) #:transparent)

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
    (for ([name (in-list '(open-webview supported? close navigate title url capture!))])
      (hash-set! backend-procs name (dynamic-require mod name))))
  backend-procs)

(define (ref name)
  (hash-ref (load-backend!) name))

(define (webview-supported?)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'supported?))))

;; open-window: high-level entry. Opens a native window with a webview
;; rendering `url`. Optional #:title, #:width, #:height, #:on-close.
;; Returns a webview? on success, or #f if the backend is unavailable.
;; With #:fallback-browser? #t the system browser is opened instead when the
;; native backend is unavailable (recommended on platforms where the WebView
;; backend is still in progress, e.g. Windows today).
(define (open-window url
                     #:title [title "Glaze"]
                     #:width [width 1024]
                     #:height [height 768]
                     #:devtools? [devtools? #f]
                     #:on-close [on-close (lambda () (void))]
                     #:fallback-browser? [fallback? #f])
  (open-webview url
                #:title title
                #:width width
                #:height height
                #:devtools? devtools?
                #:on-close on-close
                #:fallback-browser? fallback?))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:devtools? [devtools? #f]
                      #:on-close [on-close (lambda () (void))]
                      #:fallback-browser? [fallback? #f])
  (define h
    (with-handlers ([exn:fail? (lambda (e)
                                 (fprintf (current-error-port)
                                          "[glaze] webview backend unavailable (~a); "
                                          (exn-message e))
                                 (displayln "use open-browser as fallback." (current-error-port))
                                 #f)])
      ((ref 'open-webview) url
        #:title title
        #:width width
        #:height height
        #:devtools? devtools?
        #:on-close on-close)))
  (cond
    [h (webview (detected-backend) h)]
    [fallback? (open-browser url) #f]
    [else #f]))

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
