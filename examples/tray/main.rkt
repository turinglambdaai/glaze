#lang racket/base

;; Minimal system tray example using only the public Glaze facade.
;; Run: racket examples/tray/main.rkt

(require glaze)

(define tray
  (make-tray
   #:icon #f
   #:tooltip "Glaze Tray"
   #:menu
   (list
    (make-menu-item "Hello"
                    #:action (lambda ()
                               (displayln "Hello from the Glaze tray")))
    (menu-separator)
    (make-menu-item "Quit"
                    #:action (lambda ()
                               (tray-close tray)
                               (exit 0))))))

(displayln "Glaze tray example is running. Use the tray menu to quit.")

(let loop ()
  (sleep 1)
  (loop))
