#lang racket/base

(require rackunit
         racket/file
         racket/string
         racket/system
         glaze/signing)

(define directory (make-temporary-file "glaze-signing-test~a" 'directory))

;; The whole suite exercises real Ed25519 operations, which LibreSSL (the
;; macOS default /usr/bin/openssl) cannot perform. Without a usable OpenSSL
;; the suite reports a skip instead of failing on the platform's CLI dialect.
;; GLAZE_OPENSSL points the suite (and the library) at a specific CLI.
(if (openssl-available?)
    (dynamic-wind
     void
     (lambda ()
       (define-values (private-key public-key)
         (signing-keygen #:private-key (build-path directory "private.pem")
                         #:public-key (build-path directory "public.pem")))

       (define artifact (build-path directory "artifact.bin"))
       (call-with-output-file artifact (lambda (output) (write-bytes (make-bytes 100000 7) output)))

       (define signature (sign-file artifact #:private-key private-key))
       (check-true (string? signature))
       (check-false (string-contains? signature "\n"))
       (check-true (verify-signature artifact #:public-key public-key #:signature signature))

       (define empty-artifact (build-path directory "empty.bin"))
       (call-with-output-file empty-artifact (lambda (_) (void)))
       (check-true (verify-signature empty-artifact
                                     #:public-key public-key
                                     #:signature (sign-file empty-artifact
                                                            #:private-key private-key)))

       (call-with-output-file artifact
                              (lambda (output) (write-bytes (make-bytes 100000 8) output))
                              #:exists 'truncate)
       (check-false (verify-signature artifact #:public-key public-key #:signature signature))

       (call-with-output-file artifact
                              (lambda (output) (write-bytes (make-bytes 100000 7) output))
                              #:exists 'truncate)
       (check-exn exn:fail?
                  (lambda ()
                    (verify-signature artifact
                                      #:public-key public-key
                                      #:signature signature
                                      #:expected-sha256 "00")))
       (check-true (verify-signature artifact
                                     #:public-key public-key
                                     #:signature signature
                                     #:expected-sha256 (sha256-file artifact)))

       (define-values (_other-private other-public)
         (signing-keygen #:private-key (build-path directory "other.pem")
                         #:public-key (build-path directory "other-public.pem")))
       (check-false (verify-signature artifact #:public-key other-public #:signature signature))

       (define-values (encrypted-private encrypted-public)
         (signing-keygen #:private-key (build-path directory "encrypted.pem")
                         #:public-key (build-path directory "encrypted-public.pem")
                         #:password "test-password"))
       (check-true (signing-key-password-encrypted? encrypted-private))
       (define encrypted-signature
         (sign-file artifact #:private-key encrypted-private #:password "test-password"))
       (check-true
        (verify-signature artifact #:public-key encrypted-public #:signature encrypted-signature))
       (check-true (string-contains? (file->string encrypted-private) "ENCRYPTED PRIVATE KEY"))
       (check-false (signing-key-password-encrypted? private-key))

       (check-equal? (sha256-file artifact) (sha256-string (file->bytes artifact)))
       (check-equal? (string-length (public-key-fingerprint public-key)) 64)

       ;; Exercise the installed CLI, including the positional artifact syntax.
       (define raco (find-executable-path "raco"))
       (define cli-keys (build-path directory "cli-keys"))
       (define cli-signature (build-path directory "artifact.sig"))
       (check-equal? (system*/exit-code raco "glaze" "updater-keygen" "--out" (path->string cli-keys))
                     0)
       (check-equal? (system*/exit-code raco
                                        "glaze"
                                        "update-sign"
                                        (path->string artifact)
                                        "--key"
                                        (path->string (build-path cli-keys "private.pem"))
                                        "--out"
                                        (path->string cli-signature))
                     0)
       (check-equal? (system*/exit-code raco
                                        "glaze"
                                        "update-verify"
                                        (path->string artifact)
                                        "--pub"
                                        (path->string (build-path cli-keys "public.pem"))
                                        "--signature"
                                        (path->string cli-signature)
                                        "--sha256"
                                        (sha256-file artifact))
                     0))
     (lambda () (delete-directory/files directory)))
    (begin
      (printf "glaze-test/signing: skipped — no OpenSSL >= 1.1.1 found (set GLAZE_OPENSSL)\n")
      (delete-directory/files directory)))
