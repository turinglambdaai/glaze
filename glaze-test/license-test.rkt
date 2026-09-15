#lang racket/base

;; License + update-integrity tests (commercialization layer). All
;; signature tests require the `openssl` CLI — present on macOS and Linux
;; out of the box and in Git-for-Windows on Windows runners.

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         glaze/build
         glaze/license
         glaze/update)

;; ---- machine-id ----

(define mid (machine-id))
(check-true (string? mid) "machine-id is a string")
(check-equal? (string-length mid) 64 "machine-id is a 64-char hex digest")
(check-true (regexp-match? #px"^[0-9a-f]{64}$" mid) "machine-id is lowercase hex")
(check-equal? (machine-id) mid "machine-id is stable across calls")

;; ---- expiry math ----

(check-true (> (days-until-expiry "2099-01-01") 0) "future expiry is positive")
(check-true (< (days-until-expiry "2000-01-01") 0) "past expiry is negative")
(check-exn exn:fail? (lambda () (days-until-expiry "not-a-date")) "malformed date raises")

;; ---- openssl presence gate ----

(define openssl? (find-executable-path "openssl" #f))

;; ---- license issue / validate roundtrip ----

(when openssl?
  (define dir (make-temporary-file "glaze-license-test-~a" 'directory))
  (define priv (build-path dir "private.pem"))
  (define pub (build-path dir "public.pem"))
  (define openssl (find-executable-path "openssl" #f))

  (check-not-exn
   (lambda ()
     (system* openssl "genpkey" "-algorithm" "RSA"
              "-pkeyopt" "rsa_keygen_bits:2048" "-out" priv))
   "keygen runs")
  (check-true (zero? (system*/exit-code openssl "pkey" "-in" priv "-pubout" "-out" pub))
              "pubkey derivation succeeds")

  (define license-path (build-path dir "app.license"))

  ;; valid license with all claims
  (check-not-exn
   (lambda ()
     (issue-license #:private-key priv
                    #:product "TestApp"
                    #:subject "customer@example.com"
                    #:expiry "2099-12-31"
                    #:machine-id mid
                    #:out license-path))
   "issuing a license runs")
  (define ok (validate-license license-path #:public-key pub #:product "TestApp"))
  (check-true (hash-ref ok 'valid) "license validates")
  (check-equal? (hash-ref ok 'subject) "customer@example.com" "subject round-trips")
  (check-equal? (hash-ref ok 'expiry) "2099-12-31" "expiry round-trips")
  (check-true (license-valid? license-path #:public-key pub #:product "TestApp")
              "boolean wrapper agrees")

  ;; wrong product
  (check-equal? (hash-ref (validate-license license-path
                                            #:public-key pub
                                            #:product "Other")
                          'reason)
                "product"
                "wrong product -> reason product")

  ;; tampered payload -> signature failure
  (define tampered-path (build-path dir "tampered.license"))
  (call-with-output-file tampered-path
                         (lambda (o)
                           (display (string-replace
                                     (file->string license-path)
                                     "customer@example.com" "attacker@evil.com")
                                    o))
                         #:exists 'replace)
  (check-equal? (hash-ref (validate-license tampered-path
                                            #:public-key pub
                                            #:product "TestApp")
                          'reason)
                "signature"
                "tampered payload -> reason signature")

  ;; expired
  (define expired-path (build-path dir "expired.license"))
  (issue-license #:private-key priv
                 #:product "TestApp"
                 #:subject "x"
                 #:expiry "2000-01-01"
                 #:out expired-path)
  (check-equal? (hash-ref (validate-license expired-path
                                            #:public-key pub
                                            #:product "TestApp")
                          'reason)
                "expired"
                "past expiry -> reason expired")

  ;; machine binding
  (define bound-path (build-path dir "bound.license"))
  (issue-license #:private-key priv
                 #:product "TestApp"
                 #:subject "x"
                 #:machine-id "deadbeef"
                 #:out bound-path)
  (check-equal? (hash-ref (validate-license bound-path
                                            #:public-key pub
                                            #:product "TestApp")
                          'reason)
                "machine"
                "foreign machine-id -> reason machine")
  (check-true (hash-ref (validate-license bound-path
                                          #:public-key pub
                                          #:product "TestApp"
                                          #:machine-id "deadbeef")
                        'valid)
              "matching machine-id validates")

  ;; missing file + malformed file
  (check-equal? (hash-ref (validate-license (build-path dir "nope.license")
                                            #:public-key pub
                                            #:product "TestApp")
                          'reason)
                "missing-file"
                "missing license -> reason missing-file")
  (define garbage-path (build-path dir "garbage.license"))
  (call-with-output-file garbage-path
                         (lambda (o) (display "{{{not json" o))
                         #:exists 'replace)
  (check-equal? (hash-ref (validate-license garbage-path
                                            #:public-key pub
                                            #:product "TestApp")
                          'reason)
                "malformed"
                "non-JSON license -> reason malformed")

  ;; wrong public key -> signature failure
  (define other-priv (build-path dir "other-private.pem"))
  (system* openssl "genpkey" "-algorithm" "RSA"
           "-pkeyopt" "rsa_keygen_bits:2048" "-out" other-priv)
  (define other-pub (build-path dir "other-public.pem"))
  (system*/exit-code openssl "pkey" "-in" other-priv "-pubout" "-out" other-pub)
  (check-equal? (hash-ref (validate-license license-path
                                            #:public-key other-pub
                                            #:product "TestApp")
                          'reason)
                "signature"
                "wrong public key -> reason signature")

  (delete-directory/files dir))

;; ---- update artifact integrity ----

(define artifact (make-temporary-file "glaze-sha-test-~a"))
(call-with-output-file artifact (lambda (o) (display #"update artifact bytes" o))
                       #:exists 'replace)

(when openssl?
  (define hex
    (let ()
      (define out (open-output-string))
      (parameterize ([current-output-port out])
        (system*/exit-code (find-executable-path "openssl" #f)
                           "dgst" "-sha256" "-r" (path->string artifact)))
      (second (regexp-match #px"^([0-9a-f]{64})" (get-output-string out)))))
  (check-true (verify-file-sha256 artifact hex) "correct digest verifies")
  (check-false (verify-file-sha256 artifact (make-string 64 #\0))
               "wrong digest fails")
  (check-true (verify-file-sha256 artifact (string-upcase hex))
              "digest comparison is case-insensitive"))

(check-false (verify-file-sha256 artifact #f) "missing manifest digest fails safely")
(check-false (verify-file-sha256 "/no/such/file" (make-string 64 #\a))
             "missing file fails safely")

(delete-directory/files artifact)
