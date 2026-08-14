#lang racket/base

;; Linux WebView backend using Racket's ffi/unsafe (no compiler required).
;;
;; Creates a GtkWindow containing a WebKitWebView and loads the given URL.
;; Requires libwebkit2gtk-4.1 (+ libgtk-3) at runtime; falls back to the stub
;; (via the dispatcher) when absent.
;;
;; STATUS (Phase 3, in progress): CI on Linux (with the webkit dev packages)
;; exercises it; it cannot run on Windows/macOS hosts.

(require ffi/unsafe
         racket/path)

(provide open-webview
         supported?
         close
         navigate
         lin:webview?)

(define gtk-lib
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "gtk-3" '("0" #f))))

(define webkit-lib
  (or (with-handlers ([exn:fail? (lambda (e) #f)])
        (ffi-lib "webkit2gtk-4.1" '("0" #f)))
      (with-handlers ([exn:fail? (lambda (e) #f)])
        (ffi-lib "webkit2gtk-4.0" '("37" #f)))))

(define (maybe-bind lib name type)
  (and lib (get-ffi-obj name lib type (lambda () #f))))

(define gtk_init (maybe-bind gtk-lib "gtk_init" (_fun _pointer _pointer -> _void)))
(define gtk_window_new (maybe-bind gtk-lib "gtk_window_new" (_fun _int -> _pointer)))
(define gtk_window_set_title
  (maybe-bind gtk-lib "gtk_window_set_title" (_fun _pointer _string -> _void)))
(define gtk_window_set_default_size
  (maybe-bind gtk-lib "gtk_window_set_default_size" (_fun _pointer _int _int -> _void)))
(define gtk_container_add (maybe-bind gtk-lib "gtk_container_add" (_fun _pointer _pointer -> _void)))
(define gtk_widget_show_all (maybe-bind gtk-lib "gtk_widget_show_all" (_fun _pointer -> _void)))
(define gtk_main (maybe-bind gtk-lib "gtk_main" (_fun -> _void)))
(define gtk_main_quit (maybe-bind gtk-lib "gtk_main_quit" (_fun -> _void)))
(define webkit_web_view_new (maybe-bind webkit-lib "webkit_web_view_new" (_fun -> _pointer)))
(define webkit_web_view_load_uri
  (maybe-bind webkit-lib "webkit_web_view_load_uri" (_fun _pointer _string -> _void)))

(struct lin:webview (window webview) #:transparent)

(define (supported?)
  (and (eq? (system-type 'os) 'unix)
       gtk-lib
       webkit-lib
       gtk_init
       gtk_window_new
       webkit_web_view_new
       webkit_web_view_load_uri
       #t))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:on-close [on-close (lambda () (void))])
  (unless (supported?)
    (error 'open-webview "Linux WebView backend not available"))

  (gtk_init #f #f)
  (define window (gtk_window_new 0)) ; GTK_WINDOW_TOPLEVEL = 0
  (gtk_window_set_title window title)
  (gtk_window_set_default_size window width height)
  (define webview (webkit_web_view_new))
  (gtk_container_add window webview)
  (webkit_web_view_load_uri webview url)
  (gtk_widget_show_all window)
  ;; Run the GTK main loop on a worker thread so the caller isn't blocked.
  ;; (GTK requires its main loop on the thread that called gtk_init; Racket
  ;; threads share one OS thread, so this is consistent.)
  (void (thread gtk_main))
  (lin:webview window webview))

(define (close wv)
  (when gtk_main_quit
    (gtk_main_quit)))

(define (navigate wv url)
  (webkit_web_view_load_uri (lin:webview-webview wv) url))
