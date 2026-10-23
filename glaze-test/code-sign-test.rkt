#lang racket/base

;; Direct contract for the code-signing owner: certificate-spec
;; classification, the timestamp default, and every sign-dist dispatch path
;; that must settle without invoking an external toolchain.

(require racket/file
         racket/port
         racket/string
         rackunit
         glaze/private/code-sign)

;; ---- certificate classification ----

(check-equal? (windows-cert-flag "0123456789012345678901234567890123456789")
              "/sha1"
              "a 40-hex string is a SHA-1 thumbprint")
(check-equal? (windows-cert-flag "012345678901234567890123456789012345678G")
              "/n"
              "40 non-hex characters are a subject name")
(check-equal? (windows-cert-flag "012345678901234567890123456789012345678")
              "/n"
              "39 characters are a subject name")
(check-equal? (windows-cert-flag "My Certificate") "/n")

(check-equal? default-timestamp-url "http://timestamp.digicert.com")

;; ---- dispatch settles without external tools ----

;; quiet: the warnings are user-facing progress by design, and drdr treats
;; non-empty stderr as failure.
(define (quiet thunk)
  (parameterize ([current-error-port (open-output-nowhere)])
    (thunk)))

;; Linux: --sign is explicitly not applicable; the build continues.
(define scratch (make-temporary-file "glaze-code-sign-~a" 'directory))
(check-not-exn (lambda () (quiet (lambda () (sign-dist 'unix scratch "App" "-" #f #t #f)))))

;; Windows without an exe: loud warning, no raise, no signtool call.
(check-not-exn (lambda ()
                 (quiet (lambda () (sign-dist 'windows scratch "App" "thumbprint" #f #t #f)))))

;; macOS without a bundle: a real error — a missing artifact must not pass.
(check-exn #rx"cannot sign: bundle not found"
           (lambda () (quiet (lambda () (sign-dist 'macosx scratch "App" "-" #f #t #f)))))

(delete-directory/files scratch)
