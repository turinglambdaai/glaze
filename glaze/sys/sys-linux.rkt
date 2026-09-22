#lang racket/base

;; Linux system-integration backend. Clipboard via GTK FFI; notifications
;; and open/reveal via notify-send / xdg-open subprocesses (the standard
;; freedesktop front-ends).

(require ffi/unsafe
         racket/path
         racket/string
         racket/system)

(provide supported?
         clipboard-set!
         clipboard-get
         notify!
         open-path
         reveal-path)

;; Racket's ffi-lib misses Debian/Ubuntu multiarch dirs on some hosts.
(define lib-search-dirs
  '("" "/lib/x86_64-linux-gnu/" "/usr/lib/x86_64-linux-gnu/"
    "/lib/aarch64-linux-gnu/" "/usr/lib/aarch64-linux-gnu/"
    "/usr/lib64/" "/usr/lib/" "/lib/"))

(define (try-ffi-lib name version)
  (for/or ([dir (in-list lib-search-dirs)])
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (if (string=? dir "")
          (ffi-lib name (list version #f))
          (ffi-lib (format "~alib~a.so~a" dir name
                           (if version (format ".~a" version) "")))))))

(define gtk-lib (try-ffi-lib "gtk-3" "0"))
(define gdk-lib (try-ffi-lib "gdk-3" "0"))
(define gobject-lib (try-ffi-lib "gobject-2.0" "0"))

(define (maybe-bind lib name type)
  (and lib (get-ffi-obj name lib type (lambda () #f))))

(define gdk_atom_intern_static_string
  (maybe-bind gdk-lib "gdk_atom_intern_static_string" (_fun _string -> _pointer)))
(define gtk_clipboard_get
  (maybe-bind gtk-lib "gtk_clipboard_get" (_fun _pointer -> _pointer)))
(define gtk_clipboard_set_text
  (maybe-bind gtk-lib "gtk_clipboard_set_text" (_fun _pointer _string _int -> _void)))
(define gtk_clipboard_wait_for_text
  (maybe-bind gtk-lib "gtk_clipboard_wait_for_text" (_fun _pointer -> _string)))
(define (clipboard-atom)
  (and gdk_atom_intern_static_string
       (gdk_atom_intern_static_string "CLIPBOARD")))

(define (supported?)
  (and (eq? (system-type 'os) 'unix)
       gtk-lib gdk-lib gtk_clipboard_get gdk_atom_intern_static_string #t))

(define (clipboard-set! text)
  (define atom (clipboard-atom))
  (define cb (and atom (gtk_clipboard_get atom)))
  ;; -1 asks GTK to measure the NUL-terminated UTF-8 byte string correctly;
  ;; Racket string-length counts characters, not bytes.
  (and cb (begin (gtk_clipboard_set_text cb text -1) #t)))

(define (clipboard-get)
  (define atom (clipboard-atom))
  (define cb (and atom (gtk_clipboard_get atom)))
  (and cb (or (gtk_clipboard_wait_for_text cb) "")))

(define (notify! title body subtitle)
  (define n (find-executable-path "notify-send"))
  (and n
       ;; notify-send has summary + body, but no portable subtitle flag. Keep
       ;; the subtitle as visible text instead of passing a malformed -h hint.
       (system* n title
                (if (non-empty-string? subtitle)
                    (string-append subtitle "\n" body)
                    body))))

(define (open-path p)
  (define x (find-executable-path "xdg-open"))
  (and x (system* x p)))

(define (reveal-path p)
  (define x (find-executable-path "xdg-open"))
  (define pp (path->complete-path (if (path? p) p (string->path p))))
  (define target
    (if (directory-exists? pp)
        pp
        (or (path-only pp) (current-directory))))
  (and x (system* x (path->string target))))
