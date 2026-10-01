#lang racket/base

(require rackunit
         racket/file
         glaze/window-state
         glaze/webview/main)

(define area (screen-area 0 0 1920 1080))

(check-equal? (normalize-window-state (window-state 100 200 800 600 #f) area)
              (window-state 100 200 800 600 #f)
              "visible geometry is unchanged")
(check-equal? (normalize-window-state (window-state 4000 3000 800 600 #t) area)
              (window-state 1120 480 800 600 #t)
              "stranded geometry is clamped onto the virtual desktop")
(check-equal? (normalize-window-state (window-state -500 -200 3000 2000 #f) area)
              (window-state 0 0 1920 1080 #f)
              "oversized geometry shrinks to the current desktop")

(define work (make-temporary-file "glaze-window-state-~a" 'directory))
(define state-path (build-path work "nested" "window.json"))
(dynamic-wind void
              (lambda ()
                (define expected (window-state -120 40 900 700 #t))
                (check-equal? (write-window-state! state-path expected) state-path)
                (check-equal? (read-window-state state-path) expected)
                (call-with-output-file state-path
                                       #:exists 'truncate/replace
                                       (lambda (output) (display "{not-json" output)))
                (check-false (read-window-state state-path) "corrupt state fails closed")
                (check-true (procedure? webview-window-state))
                (check-true (procedure? webview-set-window-state!))
                (check-true (procedure? webview-save-state!))
                (check-true (procedure? webview-restore-state!)))
              (lambda ()
                (when (directory-exists? work)
                  (delete-directory/files work))))
