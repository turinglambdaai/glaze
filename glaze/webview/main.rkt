#lang racket/base

;; Public WebView API. Opens a native OS window with an embedded WebView
;; control pointing at a URL (typically the local HTTP server Glaze started).
;; Platform-specific FFI stays behind this dispatcher.

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

(require (only-in "../browser.rkt" open-browser)
         (only-in "../tray/tray-protocol.rkt" menu?))

;; A webview handle wraps the backend-specific handle + the backend tag.
(struct webview (backend handle) #:transparent)

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

(define (webview-supported?)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'supported?))))

;; Keep argument failures at the public facade rather than letting malformed
;; values reach platform FFI, where errors differ by OS and can be much less
;; actionable.
(define (check-open-args who url title width height devtools? background-active?
                         on-close fallback?)
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
    (raise-argument-error who "procedure?" on-close))
  (unless (boolean? fallback?)
    (raise-argument-error who "boolean?" fallback?)))

(define (check-webview who wv)
  (unless (webview? wv)
    (raise-argument-error who "webview?" wv)))

;; open-window: high-level entry. Opens a native window with a webview
;; rendering `url`. Returns a webview? on success, or #f if the backend is
;; unavailable. With #:fallback-browser? #t the system browser is opened
;; instead when the native backend is unavailable.
(define (open-window url
                     #:title [title "Glaze"]
                     #:width [width 1024]
                     #:height [height 768]
                     #:devtools? [devtools? #f]
                     #:background-active? [background-active? #f]
                     #:on-close [on-close (lambda () (void))]
                     #:fallback-browser? [fallback? #f])
  (check-open-args 'open-window url title width height devtools?
                   background-active? on-close fallback?)
  (open-webview url
                #:title title
                #:width width
                #:height height
                #:devtools? devtools?
                #:background-active? background-active?
                #:on-close on-close
                #:fallback-browser? fallback?))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:devtools? [devtools? #f]
                      #:background-active? [background-active? #f]
                      #:on-close [on-close (lambda () (void))]
                      #:fallback-browser? [fallback? #f])
  (check-open-args 'open-webview url title width height devtools?
                   background-active? on-close fallback?)
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
        #:background-active? background-active?
        #:on-close on-close)))
  (cond
    [h
     (define wv (webview (detected-backend) h))
     (hash-set! open-registry wv #t)
     wv]
    [fallback? (open-browser url) #f]
    [else #f]))

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

;; ---- verification APIs ----

(define (webview-title wv)
  (check-webview 'webview-title wv)
  ((ref 'title) (webview-handle wv)))

(define (webview-url wv)
  (check-webview 'webview-url wv)
  ((ref 'url) (webview-handle wv)))

;; Captures the window contents to a PNG. dest defaults to a fresh temp file.
(define (webview-capture! wv [dest #f])
  (check-webview 'webview-capture! wv)
  (unless (or (not dest) (path? dest) (string? dest))
    (raise-argument-error 'webview-capture! "(or/c #f path? string?)" dest))
  ((ref 'capture!) (webview-handle wv) dest))

;; ---- window controls ----
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

;; ---- menu bar ----
(define (webview-set-menu! wv menus)
  (check-webview 'webview-set-menu! wv)
  (unless (and (list? menus) (andmap menu? menus))
    (raise-argument-error 'webview-set-menu! "(listof menu?)" menus))
  ((ref 'set-menu!) (webview-handle wv) menus))

;; ---- multi-window ----
(define (webview-closed? wv)
  (check-webview 'webview-closed? wv)
  ((ref 'closed?) (webview-handle wv)))

(define (all-webviews)
  (for/list ([(wv _) (in-hash open-registry)]) wv))

(define (close-all-webviews!)
  (for ([wv (in-list (all-webviews))] #:unless (webview-closed? wv))
    (webview-close wv)))

;; Block until every open window is closed (OS chrome closes included), or
;; until timeout-secs elapse. Returns #t when all closed, #f on timeout.
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
