#lang racket/base

;; Linux system-integration backend. Clipboard via GTK FFI; notifications
;; and open/reveal via notify-send / xdg-open subprocesses (the standard
;; freedesktop front-ends).

(require ffi/unsafe
         racket/path
         racket/string
         racket/system
         "../ffi-discovery.rkt")

(provide supported?
         clipboard-set!
         clipboard-get
         notify!
         open-path
         reveal-path)

;; Racket's ffi-lib misses Debian/Ubuntu multiarch dirs on some hosts —
;; shared with the other backends via ../ffi-discovery.rkt.
(define try-ffi-lib ffi-lib*)

(define gtk-lib (try-ffi-lib "gtk-3" '("0")))
(define gobject-lib (try-ffi-lib "gobject-2.0" '("0")))

(define (maybe-bind lib name type)
  (and lib (get-ffi-obj name lib type (lambda () #f))))

(define gtk_clipboard_get (maybe-bind gtk-lib "gtk_clipboard_get" (_fun _int -> _pointer)))
(define gtk_clipboard_set_text
  (maybe-bind gtk-lib "gtk_clipboard_set_text" (_fun _pointer _string _int -> _void)))
(define gtk_clipboard_wait_for_text
  (maybe-bind gtk-lib "gtk_clipboard_wait_for_text" (_fun _pointer -> _string)))
(define CLIPBOARD 69) ; GDK_SELECTION_CLIPBOARD atom id on X11

(define (supported?)
  (and (eq? (system-type 'os) 'unix) gtk-lib gtk_clipboard_get #t))

(define (clipboard-set! text)
  (define cb (gtk_clipboard_get CLIPBOARD))
  (and cb
       (begin
         (gtk_clipboard_set_text cb text (string-length text))
         #t)))

(define (clipboard-get)
  (define cb (gtk_clipboard_get CLIPBOARD))
  (and cb (or (gtk_clipboard_wait_for_text cb) "")))

(define (notify! title body subtitle)
  (define n (find-executable-path "notify-send"))
  (and n
       (if (non-empty-string? subtitle)
           (system* n title body (string-append "-h" subtitle))
           (system* n title body))))

(define (open-path p)
  (define x (find-executable-path "xdg-open"))
  (and x (system* x p)))

(define (reveal-path p)
  (define x (find-executable-path "xdg-open"))
  (and x (system* x (path->string (path-only (string->path p))))))
