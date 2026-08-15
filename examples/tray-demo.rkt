#lang racket/base

;; Cross-platform system tray demo: icon in the menu bar / notification area
;; with a working menu. Quit from the tray menu.
;;
;; Run: racket examples/tray-demo.rkt

(require glaze)

(define t
  (make-tray #:icon #f
             #:tooltip "Glaze Tray Demo"
             #:menu (list
                     (make-menu-item "About"
                                     #:action (lambda ()
                                                (displayln "[tray] Glaze tray demo")))
                     (menu-separator)
                     (make-menu-item "Update tooltip"
                                     #:action (lambda ()
                                                (tray-set-tooltip! t "updated!")))
                     (menu-separator)
                     (make-menu-item "Quit"
                                     #:action (lambda () (exit 0))))))

(displayln "[tray] icon is live — use the tray menu to quit")
;; Keep the process alive for the tray; the Quit menu item exits.
(let loop () (sleep 1) (loop))
