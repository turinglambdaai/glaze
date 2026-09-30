#lang racket/base

;; Ed25519 artifact signing for self-updating apps, implemented through the
;; system OpenSSL CLI so Glaze does not add a compiled crypto dependency.
;; Signatures cover "sha256:<hex digest>" rather than loading the artifact in
;; memory, which keeps the format suitable for large release archives.

(require racket/list
         net/base64
         racket/file
         racket/port
         racket/string
         racket/system)

(provide signing-keygen
         signing-key-password-encrypted?
         sign-file
         verify-signature
         sha256-file
         sha256-string
         public-key-fingerprint)

(define (find-openssl)
  (define executable (find-executable-path "openssl" #f))
  (unless executable
    (error 'signing "openssl not found on PATH"))
  executable)

(define (->path value)
  (if (path? value)
      value
      (string->path value)))

(define (delete-if-present path)
  (when (and path (file-exists? path))
    (delete-file path)))

(define (openssl-run operation arguments)
  (define exit-code (apply system*/exit-code (find-openssl) arguments))
  (unless (zero? exit-code)
    (error 'signing "~a failed (openssl exit ~a)" operation exit-code)))

(define (write-content-file path content)
  (call-with-output-file path
                         (lambda (output)
                           (if (bytes? content)
                               (write-bytes content output)
                               (display content output)))
                         #:exists 'replace))

(define (sha256-file path-value)
  (define path (->path path-value))
  (define output (make-temporary-file "glaze-dgst~a"))
  (dynamic-wind
   void
   (lambda ()
     (openssl-run "sha256"
                  (list "dgst" "-sha256" "-r" "-out" (path->string output) (path->string path)))
     (define match (regexp-match #px"^([0-9a-f]{64})" (string-trim (file->string output))))
     (unless match
       (error 'signing "openssl returned an invalid sha256 digest"))
     (second match))
   (lambda () (delete-if-present output))))

(define (sha256-string content)
  (unless (or (string? content) (bytes? content))
    (raise-argument-error 'sha256-string "(or/c string? bytes?)" content))
  (define input (make-temporary-file "glaze-dgst-in~a"))
  (dynamic-wind void
                (lambda ()
                  (write-content-file input content)
                  (sha256-file input))
                (lambda () (delete-if-present input))))

(define (public-key-fingerprint public-key-value)
  (define public-key (->path public-key-value))
  (define der (make-temporary-file "glaze-pub-der~a"))
  (dynamic-wind void
                (lambda ()
                  (openssl-run "public-key fingerprint"
                               (list "pkey"
                                     "-pubin"
                                     "-in"
                                     (path->string public-key)
                                     "-outform"
                                     "DER"
                                     "-out"
                                     (path->string der)))
                  (sha256-file der))
                (lambda () (delete-if-present der))))

(define (signing-key-password-encrypted? private-key-path)
  (string-contains? (file->string private-key-path) "ENCRYPTED"))

(define (signing-keygen #:private-key private-value
                        #:public-key public-value
                        #:password [password #f])
  (define private-path (->path private-value))
  (define public-path (->path public-value))
  (define temporary-private (make-temporary-file "glaze-keygen~a"))
  (define password-file (and password (make-temporary-file "glaze-keygen-pw~a")))
  (dynamic-wind
   void
   (lambda ()
     (openssl-run "key generation"
                  (list "genpkey" "-algorithm" "ED25519" "-out" (path->string temporary-private)))
     (openssl-run "public-key generation"
                  (list "pkey"
                        "-in"
                        (path->string temporary-private)
                        "-pubout"
                        "-out"
                        (path->string public-path)))
     (if password-file
         (begin
           (write-content-file password-file password)
           (openssl-run "private-key encryption"
                        (list "pkcs8"
                              "-topk8"
                              "-v2"
                              "aes-256-cbc"
                              "-in"
                              (path->string temporary-private)
                              "-passout"
                              (string-append "file:" (path->string password-file))
                              "-out"
                              (path->string private-path))))
         (openssl-run
          "private-key export"
          (list "pkey" "-in" (path->string temporary-private) "-out" (path->string private-path))))
     (values private-path public-path))
   (lambda ()
     (delete-if-present temporary-private)
     (delete-if-present password-file))))

(define (sign-file path-value #:private-key private-key-value #:password [password #f])
  (define path (->path path-value))
  (define private-key (->path private-key-value))
  (define payload-file (make-temporary-file "glaze-sig-in~a"))
  (define signature-file (make-temporary-file "glaze-sig-out~a"))
  (define password-file (and password (make-temporary-file "glaze-sig-pw~a")))
  (dynamic-wind
   void
   (lambda ()
     (write-content-file payload-file (string-append "sha256:" (sha256-file path)))
     (when password-file
       (write-content-file password-file password))
     (openssl-run
      "artifact signing"
      (append (list "pkeyutl" "-sign" "-rawin" "-inkey" (path->string private-key))
              (if password-file
                  (list "-passin" (string-append "file:" (path->string password-file)))
                  '())
              (list "-in" (path->string payload-file) "-out" (path->string signature-file))))
     (string-trim (bytes->string/utf-8 (base64-encode (file->bytes signature-file) #""))))
   (lambda ()
     (delete-if-present payload-file)
     (delete-if-present signature-file)
     (delete-if-present password-file))))

(define (verify-signature path-value
                          #:public-key public-key-value
                          #:signature signature-base64
                          #:expected-sha256 [expected-sha256 #f])
  (define path (->path path-value))
  (define public-key (->path public-key-value))
  (define digest (sha256-file path))
  (when (and expected-sha256 (not (string=? digest (string-downcase (string-trim expected-sha256)))))
    (error 'signing "artifact sha256 mismatch: expected ~a, artifact is ~a" expected-sha256 digest))
  (define payload-file (make-temporary-file "glaze-ver-in~a"))
  (define signature-file (make-temporary-file "glaze-ver-sig~a"))
  (dynamic-wind
   void
   (lambda ()
     (write-content-file payload-file (string-append "sha256:" digest))
     (write-content-file signature-file
                         (base64-decode (string->bytes/utf-8 (string-trim signature-base64))))
     (zero? (system*/exit-code (find-openssl)
                               "pkeyutl"
                               "-verify"
                               "-rawin"
                               "-pubin"
                               "-inkey"
                               (path->string public-key)
                               "-sigfile"
                               (path->string signature-file)
                               "-in"
                               (path->string payload-file))))
   (lambda ()
     (delete-if-present payload-file)
     (delete-if-present signature-file))))
