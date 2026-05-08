#lang racket/base

(require rackunit
         glaze/server
         glaze/browser
         glaze/assets
         racket/file
         racket/port)

;; Server tests
(check-equal? (procedure? start-dev-server) #t "start-dev-server is a procedure")
(check-equal? (procedure? stop-server) #t "stop-server is a procedure")

;; Browser tests
(check-equal? (procedure? open-browser) #t "open-browser is a procedure")

;; Assets tests
(define tmp-dir (make-temporary-file "glaze-test-~a" 'directory))
(check-not-exn (lambda () (ensure-public-dir tmp-dir)) "ensure-public-dir creates dir")
(check-true (directory-exists? tmp-dir) "public dir exists")
(delete-directory/files tmp-dir)
