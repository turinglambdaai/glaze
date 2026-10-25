#lang racket/base

;; Platform-agnostic menu/tray protocol: menu data structures shared by the
;; tray and webview platform backends. Platform backends translate these
;; structs into native menus (Win32 TrackPopupMenu / menu bar, NSMenu,
;; GtkMenu) and invoke the matching callback when a menu id fires; native
;; menu-id allocation lives in glaze/private/id-allocator.

(provide (struct-out menu-item)
         make-menu-item
         menu-separator
         menu-item?
         menu-separator?
         (struct-out menu)
         make-menu)

;; A menu item. Separators have label #f and id #f. Normal items carry a label,
;; a stable id (string, user-provided for stable dispatch) and an action thunk.
;; `enabled?` and `checked?` are hints the backend may honor when supported.
(struct menu-item (label id action enabled? checked? accel) #:transparent)

(define (make-menu-item label
                        #:id [id label]
                        #:action [action (lambda () (void))]
                        #:enabled? [enabled? #t]
                        #:checked? [checked? #f]
                        #:accel [accel #f])
  (menu-item label id action enabled? checked? accel))

(define (menu-separator)
  (menu-item #f #f (lambda () (void)) #t #f #f))

(define (menu-separator? mi)
  (and (menu-item? mi) (not (menu-item-label mi))))

;; A top-level menu (menubar title + its entries) for menu bars. `items`
;; holds menu-item? values; a menu bar is a list of `menu?` values.
(struct menu (title items) #:transparent)

(define (make-menu title items)
  (menu title items))
