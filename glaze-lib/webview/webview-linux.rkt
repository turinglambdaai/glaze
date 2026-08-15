#lang racket/base

;; Linux WebView backend using Racket's ffi/unsafe (no compiler required).
;;
;; Creates a GtkWindow containing a WebKitWebView and loads the given URL.
;; Requires libwebkit2gtk-4.1 (+ libgtk-3, libglib-2.0, libgobject-2.0) at
;; runtime; falls back to the stub (via the dispatcher) when absent.
;;
;; STATUS (Phase 3, in progress): structurally complete — mirrors the
;; verified macOS backend's design — but NOT locally verified (no Linux
;; dev host here; CI compiles it and exercises what a headless session
;; allows). Known-good pattern applied:
;;
;;   - gtk_main must NEVER be called from Racket: it is a blocking FFI call
;;     and would freeze every Racket thread (Racket threads share one OS
;;     thread). Instead a pump thread iterates the shared GLib main context
;;     with g_main_context_iteration(NULL, FALSE) and sleeps between
;;     iterations — the same discipline as the macOS runMode pump.
;;   - on-close is delivered via the GtkWidget "destroy" signal; the
;;     callback is kept alive in a registry keyed by the window pointer
;;     (same idea as the macOS windowWillClose: delegate registry).
;;
;; FFI notes:
;;   - g_signal_connect_data's GCallback must be created with function-ptr
;;     and kept alive forever (GTK stores the raw pointer).

(require ffi/unsafe
         racket/path
         racket/string)

(provide open-webview
         supported?
         close
         navigate
         title
         url
         capture!
         lin:webview?)

(define gtk-lib
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "gtk-3" '("0" #f))))

(define webkit-lib
  (or (with-handlers ([exn:fail? (lambda (e) #f)])
        (ffi-lib "webkit2gtk-4.1" '("0" #f)))
      (with-handlers ([exn:fail? (lambda (e) #f)])
        (ffi-lib "webkit2gtk-4.0" '("37" #f)))))

(define glib-lib
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "glib-2.0" '("0" #f))))

(define gobject-lib
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "gobject-2.0" '("0" #f))))

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
(define gtk_widget_destroy (maybe-bind gtk-lib "gtk_widget_destroy" (_fun _pointer -> _void)))
(define webkit_web_view_new (maybe-bind webkit-lib "webkit_web_view_new" (_fun -> _pointer)))
(define webkit_web_view_load_uri
  (maybe-bind webkit-lib "webkit_web_view_load_uri" (_fun _pointer _string -> _void)))
(define webkit_web_view_get_title
  (maybe-bind webkit-lib "webkit_web_view_get_title" (_fun _pointer -> _string)))
(define webkit_web_view_get_uri
  (maybe-bind webkit-lib "webkit_web_view_get_uri" (_fun _pointer -> _string)))
(define g_main_context_iteration
  (maybe-bind glib-lib "g_main_context_iteration" (_fun _pointer _bool -> _bool)))
(define g_signal_connect_data
  (maybe-bind gobject-lib
              "g_signal_connect_data"
              (_fun _pointer _string _fpointer _pointer _pointer _uint -> _uintptr)))

(struct lin:webview (window webview [url #:mutable] closed?-box [thread #:mutable])
  #:transparent)

(define (supported?)
  (and (eq? (system-type 'os) 'unix)
       gtk-lib
       webkit-lib
       gtk_init
       gtk_window_new
       webkit_web_view_new
       webkit_web_view_load_uri
       g_main_context_iteration
       g_signal_connect_data
       #t))

;; window-pointer -> on-close thunk registry (GTK "destroy" callback side).
(define close-callbacks (make-hasheq))
(define callbacks-sema (make-semaphore 1))
;; Callback function pointers must outlive the connection.
(define callback-ptrs '())

(define (connect-on-close! window on-close)
  (define (on-destroy widget data)
    (define proc (call-with-semaphore callbacks-sema
                                  (lambda () (hash-ref close-callbacks (cast widget _pointer _uintptr) #f))))
    (when (procedure? proc) (proc)))
  (define cptr (function-ptr on-destroy (_fun _pointer _pointer -> _void)))
  (set! callback-ptrs (cons cptr callback-ptrs))
  (call-with-semaphore callbacks-sema
                       (lambda ()
                         (hash-set! close-callbacks (cast window _pointer _uintptr) on-close)))
  (g_signal_connect_data window "destroy" cptr #f #f 0))

(define (pump-loop wv)
  (let loop ()
    (unless (unbox (lin:webview-closed?-box wv))
      ;; Non-blocking iteration of the shared default main context (the one
      ;; gtk_init installed); FALSE = don't block waiting for events.
      (g_main_context_iteration #f #f)
      ;; Mandatory scheduler yield — same reasoning as the macOS pump.
      (sleep 0.005)
      (loop))))

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

  (define closed? (box #f))
  (connect-on-close! window (lambda () (set-box! closed? #t) (on-close)))

  (define wv (lin:webview window webview url closed? #f))
  (set-lin:webview-thread! wv (thread (lambda () (pump-loop wv))))
  wv)

(define (close wv)
  (unless (unbox (lin:webview-closed?-box wv))
    (gtk_widget_destroy (lin:webview-window wv))))

(define (navigate wv url)
  (set-lin:webview-url! wv url)
  (webkit_web_view_load_uri (lin:webview-webview wv) url))

;; Verification APIs. title/uri reflect the committed navigation once
;; WebKitGTK reports it; capture would need gdk_pixbuf plumbing (pending).
(define (title wv)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define t (webkit_web_view_get_title (lin:webview-webview wv)))
    (and (non-empty-string? t) t)))

(define (url wv)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define u (webkit_web_view_get_uri (lin:webview-webview wv)))
    (and (non-empty-string? u) u)))

(define (capture! wv [dest #f])
  #f)
