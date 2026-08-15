#lang racket/base

;; Linux tray backend using Racket's ffi/unsafe to bind
;; libayatana-appindicator + libgtk-3 (no compiler required).
;;
;; Strategy:
;;   - Load libayatana-appindicator3 (fallback to libappindicator3) and
;;     libgtk-3 + libgobject-2.0 at runtime. If any is missing, raise so the
;;     public dispatcher falls back to the stub (with a stderr warning). This
;;     lets the tray gracefully degrade on minimal Linux installs or Wayland
;;     sessions without the indicator extension.
;;   - app_indicator_new creates the indicator; set its label/icon/status.
;;   - Build a GtkMenu from the menu items; each GtkMenuItem's "activate"
;;     signal is wired to its Racket action via g_signal_connect_data and a
;;     per-item function pointer kept alive in a registry (GC would otherwise
;;     reclaim it and the next click jumps into freed memory).
;;
;; IMPORTANT: this module only loads on 'unix via dynamic-require. CI on Linux
;; (with libayatana-appindicator3-dev + libgtk-3-dev installed) exercises it.

(require ffi/unsafe
         racket/path
         "tray-protocol.rkt")

(provide make-tray
         set-tooltip!
         set-icon!
         set-menu!
         close
         supported?
         lin:tray?)


;; Racket's ffi-lib misses Debian/Ubuntu multiarch dirs on some hosts;
;; try the bare soname first, then common absolute locations.
(define lib-search-dirs
  '("" "/lib/x86_64-linux-gnu/" "/usr/lib/x86_64-linux-gnu/"
    "/lib/aarch64-linux-gnu/" "/usr/lib/aarch64-linux-gnu/"
    "/usr/lib64/" "/usr/lib/" "/lib/"))

(define (try-ffi-lib name version)
  (for/or ([dir (in-list lib-search-dirs)])
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (if (string=? dir "")
          (ffi-lib name (list version #f))
          (ffi-lib (format "~a~a.so~a" dir name (if version (format ".~a" version) "")))))))


;; Load the indicator library; try ayatana first, then legacy appindicator.
(define indicator-lib
  (or (try-ffi-lib "ayatana-appindicator3" "1")
      (with-handlers ([exn:fail? (lambda (e) #f)])
        (try-ffi-lib "appindicator" "3"))
      (with-handlers ([exn:fail? (lambda (e) #f)])
        (try-ffi-lib "appindicator3" "1"))))

(define gtk-lib (try-ffi-lib "gtk-3" "0"))

(define gobject-lib (try-ffi-lib "gobject-2.0" "0"))

;; Bindings (resolved only if the libraries loaded; otherwise #f).
(define (maybe-bind lib name type)
  (and lib (get-ffi-obj name lib type (lambda () #f))))

(define app_indicator_new
  (maybe-bind indicator-lib "app_indicator_new" (_fun _string _string _int -> _pointer)))

(define app_indicator_set_status
  (maybe-bind indicator-lib "app_indicator_set_status" (_fun _pointer _int -> _void)))

(define app_indicator_set_label
  (maybe-bind indicator-lib "app_indicator_set_label" (_fun _pointer _string _string -> _void)))

(define app_indicator_set_icon_full
  (maybe-bind indicator-lib "app_indicator_set_icon_full" (_fun _pointer _string _string -> _void)))

(define app_indicator_set_menu
  (maybe-bind indicator-lib "app_indicator_set_menu" (_fun _pointer _pointer -> _void)))

(define gtk_menu_new (maybe-bind gtk-lib "gtk_menu_new" (_fun -> _pointer)))

(define gtk_menu_item_new_with_label
  (maybe-bind gtk-lib "gtk_menu_item_new_with_label" (_fun _string -> _pointer)))

(define gtk_separator_menu_item_new
  (maybe-bind gtk-lib "gtk_separator_menu_item_new" (_fun -> _pointer)))

(define gtk_menu_shell_append
  (maybe-bind gtk-lib "gtk_menu_shell_append" (_fun _pointer _pointer -> _void)))

(define gtk_widget_show_all (maybe-bind gtk-lib "gtk_widget_show_all" (_fun _pointer -> _void)))

(define g_signal_connect_data
  (maybe-bind gobject-lib
              "g_signal_connect_data"
              (_fun _pointer _string _pointer _pointer _pointer _int -> _uint)))

;; Indicator status enum: APP_INDICATOR_STATUS_ACTIVE = 1.
(define INDICATOR-STATUS-ACTIVE 1)

;; Keep activation function pointers alive (one per menu item) so the GC does
;; not reclaim them. A reclaimed handler = crash on click.
(define activation-closures (box '()))

(define (remember-closure! c)
  (set-box! activation-closures (cons c (unbox activation-closures))))

(define (clear-closures!)
  (set-box! activation-closures '()))

;; The tray handle holds the indicator + the current menu.
(struct lin:tray (indicator [menu-box #:mutable]) #:transparent)

(define (supported?)
  (and (eq? (system-type 'os) 'unix)
       indicator-lib
       gtk-lib
       gobject-lib
       app_indicator_new
       gtk_menu_new
       g_signal_connect_data
       #t))

(define (make-tray #:icon icon-path
                   #:tooltip tooltip
                   #:menu items
                   #:on-event [on-event (lambda (e) (void))])
  (unless (supported?)
    (error 'make-tray
           (string-append "Linux tray backend not available (need libayatana-appindicator3"
                          " + libgtk-3 + libgobject-2.0); falling back to stub")))

  ;; appindicator takes an icon-name (theme icon) or absolute path.
  (define icon-name
    (if (and icon-path (file-exists? icon-path))
        (path->string icon-path)
        "applications-development"))

  (define indicator (app_indicator_new "glaze-app" icon-name INDICATOR-STATUS-ACTIVE))
  (app_indicator_set_status indicator INDICATOR-STATUS-ACTIVE)
  (when (string? tooltip)
    (app_indicator_set_label indicator tooltip ""))

  (define menu (build-menu items))
  (app_indicator_set_menu indicator menu)

  (lin:tray indicator menu))

;; Build a GtkMenu from a list of menu-items; wires "activate" signals.
(define (build-menu items)
  (clear-closures!)
  (define menu (gtk_menu_new))
  (for ([mi (in-list items)])
    (define widget
      (cond
        [(menu-separator? mi) (gtk_separator_menu_item_new)]
        [else
         (define w (gtk_menu_item_new_with_label (or (menu-item-label mi) "")))
         (define act (menu-item-action mi))
         ;; g_signal_connect_data: instance, detailed_signal "activate",
         ;; c_handler (function pointer), data (#f), destroy_data (#f),
         ;; connect_flags (0).
         (define cb (function-ptr act (_fun _pointer _pointer -> _void)))
         (remember-closure! cb)
         (g_signal_connect_data w "activate" cb #f #f 0)
         w]))
    (gtk_menu_shell_append menu widget)
    (gtk_widget_show_all widget))
  (gtk_widget_show_all menu)
  menu)

(define (set-tooltip! t tooltip)
  (when (string? tooltip)
    (app_indicator_set_label (lin:tray-indicator t) tooltip "")))

(define (set-icon! t icon-path)
  (when (and icon-path (file-exists? icon-path))
    (app_indicator_set_icon_full (lin:tray-indicator t) (path->string icon-path) "icon")))

(define (set-menu! t items)
  (define menu (build-menu items))
  (set-lin:tray-menu-box! t menu)
  (app_indicator_set_menu (lin:tray-indicator t) menu))

(define (close t)
  ;; AppIndicator has no explicit destroy; clear our activation closures so
  ;; they can be GC'd. The indicator object is reclaimed when the handle is.
  (clear-closures!))
