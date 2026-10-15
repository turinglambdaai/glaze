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
         sign-bytes
         verify-bytes
         sign-file
         verify-signature
         sha256-file
         sha256-string
         public-key-fingerprint
         openssl-path
         openssl-available?)

;; Ed25519 through the pkeyutl CLI needs OpenSSL >= 3.0: 3.0 made the
;; algorithm available to pkeyutl (with the mandatory -rawin flag) while
;; 1.1.x's EVP rejects Ed25519 at sign-init outright. macOS ships
;; /usr/bin/openssl as LibreSSL, which lacks Ed25519 entirely and fails
;; with an opaque exit code, so the CLI is chosen by capability rather
;; than by PATH accident:
;;   1. the GLAZE_OPENSSL environment variable (explicit override);
;;   2. `openssl` on PATH, accepted only when `openssl version` reports
;;      OpenSSL >= 3.0 (LibreSSL and older OpenSSL are skipped);
;;   3. well-known Homebrew locations on macOS.
;; When nothing usable exists, every operation raises one actionable error
;; naming the remedy instead of a cryptic pkeyutl failure.

(define min-openssl-version '(3 0 0))

(define openssl-version-regexp #rx"^OpenSSL ([0-9]+)\\.([0-9]+)\\.([0-9]+)")

(define (version-at-least? v minimum)
  (cond
    [(null? minimum) #t]
    [(null? v) #f]
    [(= (car v) (car minimum)) (version-at-least? (cdr v) (cdr minimum))]
    [else (> (car v) (car minimum))]))

(define (openssl-usable? executable)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define out
      (with-output-to-string (lambda ()
                               (unless (zero? (system*/exit-code executable "version"))
                                 (error 'signing "version probe exited non-zero")))))
    (define match (regexp-match openssl-version-regexp out))
    (define version (and match (map string->number (cdr match))))
    (when version
      (set-box! openssl-version-cache version))
    (and version (version-at-least? version min-openssl-version))))

(define openssl-cache (box #f))
;; (list major minor patch) of the accepted CLI, cached by the probe:
;; pkeyutl's Ed25519 syntax differs across the 1.1.1 / 3.x line (-rawin
;; is mandatory on 3.x and does not exist on 1.1.1).
(define openssl-version-cache (box #f))

;; OpenSSL 3 requires -rawin for raw-data algorithms like Ed25519; 1.1.1
;; feeds the raw input without the flag and rejects it as unknown.
(define (use-rawin?)
  (version-at-least? (or (unbox openssl-version-cache) '(3 0 0)) '(3 0 0)))

(define (candidate-executable candidate)
  (cond
    [(equal? candidate "openssl") (find-executable-path "openssl" #f)]
    [(file-exists? candidate) candidate]
    [else #f]))

(define (discover-openssl)
  (define candidates
    (append (list (getenv "GLAZE_OPENSSL") "openssl")
            (if (eq? (system-type 'os) 'macosx)
                (list "/opt/homebrew/opt/openssl@3/bin/openssl"
                      "/opt/homebrew/opt/openssl/bin/openssl"
                      "/usr/local/opt/openssl@3/bin/openssl"
                      "/usr/local/opt/openssl/bin/openssl")
                '())))
  (for/or ([candidate (in-list candidates)]
           #:when candidate)
    (define exe (candidate-executable candidate))
    (and exe (openssl-usable? exe) (path->complete-path exe))))

(define (no-openssl-error)
  (error 'signing
         (string-append
          "no usable OpenSSL found: Ed25519 signing requires the OpenSSL 3 CLI\n"
          "  (macOS ships /usr/bin/openssl as LibreSSL, which cannot sign Ed25519)\n"
          "  install OpenSSL 3, e.g. `brew install openssl@3` or your distro's openssl 3 package,\n"
          "  or point GLAZE_OPENSSL at a full OpenSSL CLI")))

;; Resolved CLI path, or #f when no usable OpenSSL exists (never raises —
;; for diagnostics and test gating).
(define (openssl-path)
  (or (unbox openssl-cache)
      (let ([found (discover-openssl)])
        (when found
          (set-box! openssl-cache found))
        found)))

(define (openssl-available?)
  (and (openssl-path) #t))

(define (require-openssl)
  (or (openssl-path) (no-openssl-error)))

(define (->path value)
  (if (path? value)
      value
      (string->path value)))

(define (delete-if-present path)
  (when (and path (file-exists? path))
    (delete-file path)))

;; Run the openssl CLI with its streams redirected to scratch files:
;; openssl writes to stdout AND stderr on success and failure alike
;; ("Signature Verified Successfully"), and inheriting the process's
;; streams would pollute clean-test / drdr runs. Returns
;; (values exit-code stderr-text).
(define (call-openssl arguments)
  (define out-file (make-temporary-file "glaze-ssl-out~a"))
  (define err-file (make-temporary-file "glaze-ssl-err~a"))
  (dynamic-wind void
                (lambda ()
                  (define out (open-output-file out-file #:exists 'replace))
                  (define err (open-output-file err-file #:exists 'replace))
                  ;; subprocess returns fewer values when the streams are ports
                  ;; rather than pipes; only the process handle matters here.
                  (define-values (proc _a _b _c)
                    (apply subprocess out #f err (require-openssl) arguments))
                  (close-output-port out)
                  (close-output-port err)
                  (subprocess-wait proc)
                  (values (subprocess-status proc) (string-trim (file->string err-file))))
                (lambda ()
                  (delete-if-present out-file)
                  (delete-if-present err-file))))

(define (openssl-run operation arguments)
  (define-values (exit-code detail) (call-openssl arguments))
  (unless (zero? exit-code)
    (error 'signing
           "~a failed (openssl exit ~a)~a"
           operation
           exit-code
           (if (string=? detail "")
               ""
               (string-append ": " detail)))))

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
  (sign-bytes (string->bytes/utf-8 (string-append "sha256:" (sha256-file path)))
              #:private-key private-key-value
              #:password password))

;; Sign arbitrary bytes with Ed25519 and return a base64 signature. This is
;; intentionally lower-level than sign-file: update manifests sign the exact
;; embedded payload bytes, while artifacts continue to sign their SHA-256
;; digest so large files are never loaded into memory.
(define (sign-bytes content #:private-key private-key-value #:password [password #f])
  (unless (bytes? content)
    (raise-argument-error 'sign-bytes "bytes?" content))
  (define private-key (->path private-key-value))
  (define payload-file (make-temporary-file "glaze-sig-in~a"))
  (define signature-file (make-temporary-file "glaze-sig-out~a"))
  (define password-file (and password (make-temporary-file "glaze-sig-pw~a")))
  (dynamic-wind
   void
   (lambda ()
     (write-content-file payload-file content)
     (when password-file
       (write-content-file password-file password))
     (openssl-run
      "Ed25519 signing"
      (append (list "pkeyutl" "-sign")
              (if (use-rawin?)
                  (list "-rawin")
                  '())
              (list "-inkey" (path->string private-key))
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
  (define digest (sha256-file path))
  (when (and expected-sha256 (not (string=? digest (string-downcase (string-trim expected-sha256)))))
    (error 'signing "artifact sha256 mismatch: expected ~a, artifact is ~a" expected-sha256 digest))
  (verify-bytes (string->bytes/utf-8 (string-append "sha256:" digest))
                #:public-key public-key-value
                #:signature signature-base64))

(define (verify-bytes content #:public-key public-key-value #:signature signature-base64)
  (unless (bytes? content)
    (raise-argument-error 'verify-bytes "bytes?" content))
  (unless (string? signature-base64)
    (raise-argument-error 'verify-bytes "string?" signature-base64))
  (define public-key (->path public-key-value))
  (define payload-file (make-temporary-file "glaze-ver-in~a"))
  (define signature-file (make-temporary-file "glaze-ver-sig~a"))
  (dynamic-wind
   void
   (lambda ()
     (write-content-file payload-file content)
     (write-content-file signature-file
                         (with-handlers ([exn:fail? (lambda (_) #"")])
                           (base64-decode (string->bytes/utf-8 (string-trim signature-base64)))))
     (define-values (exit-code _detail)
       (call-openssl (append (list "pkeyutl" "-verify")
                             (if (use-rawin?)
                                 (list "-rawin")
                                 '())
                             (list "-pubin"
                                   "-inkey"
                                   (path->string public-key)
                                   "-sigfile"
                                   (path->string signature-file)
                                   "-in"
                                   (path->string payload-file)))))
     (zero? exit-code))
   (lambda ()
     (delete-if-present payload-file)
     (delete-if-present signature-file))))
