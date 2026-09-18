#lang racket/base

(require rackunit
         racket/file
         (submod glaze/server test-support))

;; DNS-rebinding guard: loopback hosts are accepted with ordinary port forms,
;; including bracketed IPv6. Other hosts must stay rejected.
(for ([host (in-list '("127.0.0.1"
                       "127.0.0.1:8080"
                       "localhost"
                       "LOCALHOST:8080"
                       "[::1]"
                       "[::1]:8080"
                       "::1"))])
  (check-true (host-string-allowed? host) (format "loopback Host accepted: ~a" host)))

(for ([host (in-list '("example.com"
                       "localhost.example.com"
                       "127.0.0.2"
                       "[::2]"
                       "[::1].example.com"))])
  (check-false (host-string-allowed? host) (format "non-loopback Host rejected: ~a" host)))

;; Static serving must never resolve a request outside public-dir.
(define parent (make-temporary-file "glaze-static-security-~a" 'directory))
(define public (build-path parent "public"))
(make-directory public)
(define inside (build-path public "index.html"))
(define outside (build-path parent "secret.txt"))
(call-with-output-file inside (lambda (out) (display "public" out)) #:exists 'replace)
(call-with-output-file outside (lambda (out) (display "secret" out)) #:exists 'replace)

(check-not-false (safe-public-candidate public '("index.html"))
                 "normal public file resolves")
(check-false (safe-public-candidate public '(".." "secret.txt"))
             "parent traversal is rejected")
(check-false (safe-public-candidate public '("sub" ".." ".." "secret.txt"))
             "normalized traversal is rejected")

(delete-directory/files parent)
