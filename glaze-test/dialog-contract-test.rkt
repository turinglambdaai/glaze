#lang racket/base

(require rackunit
         glaze/dialogs)

;; OPENFILENAMEW multi-select buffers are directory\0name1\0name2\0\0 in
;; UTF-16. Keep this pure so it runs on every CI host.
(define multi
  (bytes-append (wstr "C:\\work")
                (wstr "one.txt")
                (wstr "two.txt")
                (bytes 0 0)))
(check-equal? (wstr-parts multi)
              (list "C:\\work" "one.txt" "two.txt")
              "UTF-16 multi-string preserves every selected filename")

;; A code unit whose low byte is NUL must not be mistaken for a terminator.
(check-equal? (wstr-parts (wstr "a\u0100b"))
              (list "a\u0100b"))

;; Public argument contracts run before backend availability checks.
(check-exn exn:fail:contract?
           (lambda () (pick-file #:title 42)))
(check-exn exn:fail:contract?
           (lambda () (pick-file #:directory 42)))
(check-exn exn:fail:contract?
           (lambda () (pick-file #:filters (list (list "Text" 42)))))
(check-exn exn:fail:contract?
           (lambda () (save-file-dialog #:default-name 42)))
