#lang racket/base

(require rackunit
         racket/file
         glaze/server
         glaze/update)

(check-exn exn:fail:contract?
           (lambda () (newer-version? "1.beta" "1.0")))
(check-exn exn:fail:contract?
           (lambda () (newer-version? "1.0" "current")))
(check-exn exn:fail:contract?
           (lambda () (check-update 42 #:current-version "1.0")))
(check-exn exn:fail:contract?
           (lambda () (check-update "http://127.0.0.1/manifest.json"
                                    #:current-version "1.beta")))

(define dir (make-temporary-file "glaze-update-contract-~a" 'directory))
(define (write-manifest name content)
  (call-with-output-file (build-path dir name)
    (lambda (out) (display content out))
    #:exists 'replace))

(write-manifest "bad-version.json"
                "{\"version\":\"2.beta\",\"url\":\"https://example.invalid/a\"}")
(write-manifest "missing-url.json"
                "{\"version\":\"2.0\"}")
(write-manifest "bad-sha.json"
                "{\"version\":\"2.0\",\"url\":\"https://example.invalid/a\",\"sha256\":\"oops\"}")
(write-manifest "good.json"
                "{\"version\":\"2.0\",\"url\":\"https://example.invalid/a\",\"notes\":\"ok\"}")

(define-values (port stop)
  (start-server #:port 18998 #:public-dir dir))
(define base (format "http://127.0.0.1:~a/" port))

(check-false (check-update (string-append base "bad-version.json")
                           #:current-version "1.0")
             "malformed remote version is ignored")
(check-false (check-update (string-append base "missing-url.json")
                           #:current-version "1.0")
             "manifest without artifact URL is ignored")
(check-false (check-update (string-append base "bad-sha.json")
                           #:current-version "1.0")
             "malformed digest is ignored")
(define info (check-update (string-append base "good.json")
                           #:current-version "1.0"))
(check-equal? (hash-ref info 'version) "2.0")
(check-equal? (hash-ref info 'notes) "ok")

(stop)
(delete-directory/files dir)
