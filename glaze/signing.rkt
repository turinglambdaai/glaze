#lang racket/base

;; Ed25519 artifact signing for self-updating apps, via the system openssl
;; CLI — the same zero-compiled-dependency approach as glaze/license.
;;
;; Trust model (the Tauri-updater property): the artifact signature is made
;; with a private key that never lives on the distribution server, and the
;; matching public key is pinned inside the installed app. A compromised
;; release server or mirror can therefore serve corrupted or stale
;; artifacts, but never a malicious one that the app will accept.
;;
;; Signatures are Ed25519 over the string "sha256:<hex digest>" of the
;; artifact — equivalent integrity/authenticity to signing the bytes, and
;; streaming-friendly for multi-hundred-megabyte files. The digest prefix
;; binds the signature to this scheme (no cross-protocol signature reuse).
;;
;; Key material handling: private keys are plaintext PEM by default (the
;; operator's key-vault — e.g. an age-encrypted sync folder — is the
;; at-rest control); #:password keygen wraps the key with AES-256-CBC so
;; the PEM itself can also be stored encrypted.

(require racket/list
         net/base64
         racket/file
         racket/format
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
  (define exe (find-executable-path "openssl" #f))
  (unless exe
    (error 'signing "openssl not found on PATH"))
  exe)

;; CLI callers hand strings; library callers hand paths — accept both.
(define (->path p)
  (if (path? p) p (string->path p)))

;; Run openssl discarding stdout (every form used here supports -out FILE);
;; raise a readable error on non-zero exit.
(define (openssl-run what args)
  (define rc (apply system*/exit-code (find-openssl) args))
  (unless (zero? rc)
    (error 'signing "~a failed (openssl exit ~a)" what rc)))

(define (file->trimmed-string path)
  (string-trim (file->string path)))

(define (write-string-file path content)
  (with-output-to-file path
    (lambda () (display content))
    #:exists 'replace))

;; SHA-256 of a file, lowercase hex (the "-r" output is "<hex> *<path>").
(define (sha256-file path)
  (set! path (->path path))
  (define out (make-temporary-file "glaze-dgst~a"))
  (openssl-run
   "sha256"
   (list "dgst" "-sha256" "-r" "-out" (path->string out)
         (path->string path)))
  (define hex (second (regexp-match #px"^([0-9a-f]{64})" (file->trimmed-string out))))
  (delete-file out)
  hex)

;; SHA-256 of a string, lowercase hex.
(define (sha256-string content)
  (define in (make-temporary-file "glaze-dgst-in~a"))
  (write-string-file in content)
  (define hex (sha256-file in))
  (delete-file in)
  hex)

;; OpenSSH-style fingerprint of a public key (sha256 of DER), lowercase hex.
(define (public-key-fingerprint public-key-path)
  (set! public-key-path (->path public-key-path))
  (define der (make-temporary-file "glaze-pub-der~a"))
  (openssl-run
   "pubkey-der"
   (list "pkey" "-pubin" "-in" (path->string public-key-path)
         "-outform" "DER" "-out" (path->string der)))
  (define hex (sha256-file der))
  (delete-file der)
  hex)

;; ---- keygen ------------------------------------------------------------------

(define (signing-key-password-encrypted? private-key-path)
  (string-contains? (file->string private-key-path) "ENCRYPTED"))

;; Generate an Ed25519 keypair. #:password encrypts the private key with
;; AES-256-CBC; when given, keep the password OUT of logs and process
;; listings — it travels through a temp file that is deleted immediately.
(define (signing-keygen #:private-key private-path
                        #:public-key public-path
                        #:password [password #f])
  (set! private-path (->path private-path))
  (set! public-path (->path public-path))
  (define tmp-priv (make-temporary-file "glaze-keygen~a"))
  (openssl-run
   "keygen"
   (list "genpkey" "-algorithm" "ED25519"
         "-out" (path->string tmp-priv)))
  (openssl-run
   "keygen-pub"
   (list "pkey" "-in" (path->string tmp-priv)
         "-pubout" "-out" (path->string public-path)))
  (if password
      (let ([pw-file (make-temporary-file "glaze-keygen-pw~a")])
        (write-string-file pw-file password)
        (openssl-run
         "keygen-encrypt"
         (list "pkcs8" "-topk8" "-v2" "aes-256-cbc"
               "-in" (path->string tmp-priv)
               "-passout" (string-append "file:" (path->string pw-file))
               "-out" (path->string private-path)))
        (delete-file pw-file))
      (begin
        (openssl-run
         "keygen-copy"
         (list "pkey" "-in" (path->string tmp-priv)
               "-out" (path->string private-path)))))
  (delete-file tmp-priv)
  (values private-path public-path))

;; ---- sign / verify -----------------------------------------------------------

;; Ed25519 signature over "sha256:<hex digest>", base64-encoded — safe to
;; paste into a JSON manifest.
(define (sign-file path
                   #:private-key private-key-path
                   #:password [password #f])
  (set! path (->path path))
  (set! private-key-path (->path private-key-path))
  (define payload (string-append "sha256:" (sha256-file path)))
  (define payload-file (make-temporary-file "glaze-sig-in~a"))
  (define sig-file (make-temporary-file "glaze-sig-out~a"))
  (write-string-file payload-file payload)
  (define args
    (append
     (list "pkeyutl" "-sign" "-rawin"
           "-inkey" (path->string private-key-path))
     (if password
         (list "-passin" (string-append "file:"
                                         (path->string
                                          (let ([pw (make-temporary-file "glaze-sig-pw~a")])
                                            (write-string-file pw password)
                                            pw))))
         '())
     (list "-in" (path->string payload-file)
           "-out" (path->string sig-file))))
  (openssl-run "sign" args)
  (define b64 (base64-encode (file->bytes sig-file) ""))
  (delete-file payload-file)
  (delete-file sig-file)
  (string-trim (bytes->string/utf-8 b64)))

;; Verify a signature produced by sign-file. Returns #t/#f — never raises
;; for a bad signature; a mismatched #:expected-sha256 raises (that is a
;; caller bug or active tampering, distinct from "wrong signature").
(define (verify-signature path
                          #:public-key public-key-path
                          #:signature signature-b64
                          #:expected-sha256 [expected-sha256 #f])
  (set! path (->path path))
  (set! public-key-path (->path public-key-path))
  (define digest (sha256-file path))
  (when (and expected-sha256
             (not (string=? digest
                            (string-trim (string-downcase expected-sha256)))))
    (error 'signing "artifact sha256 mismatch: expected ~a, artifact is ~a"
           expected-sha256 digest))
  (define payload (string-append "sha256:" digest))
  (define payload-file (make-temporary-file "glaze-ver-in~a"))
  (define sig-file (make-temporary-file "glaze-ver-sig~a"))
  (write-string-file payload-file payload)
  (with-output-to-file sig-file
    (lambda () (write-bytes (base64-decode (string->bytes/utf-8 (string-trim signature-b64)))))
    #:exists 'replace)
  (define rc
    (system*/exit-code (find-openssl)
                       "pkeyutl" "-verify" "-rawin"
                       "-pubin" "-inkey" (path->string public-key-path)
                       "-sigfile" (path->string sig-file)
                       "-in" (path->string payload-file)))
  (delete-file payload-file)
  (delete-file sig-file)
  (zero? rc))
