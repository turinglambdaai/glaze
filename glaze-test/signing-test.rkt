#lang racket/base

;; Ed25519 artifact signing: roundtrip, tamper detection, wrong-key
;; rejection, password-encrypted keygen. These are the primitives a
;; self-updating app pins its updater public key on — a false accept here
;; is a remote-code-execution vector, so the negative cases matter as much
;; as the positive one.

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         glaze/signing)

(define dir (make-temporary-file "glaze-signing-test~a" 'directory))
(define-values (priv pub)
  (signing-keygen #:private-key (build-path dir "private.pem")
                  #:public-key (build-path dir "public.pem")))

;; ---- roundtrip ---------------------------------------------------------------

(define artifact (build-path dir "artifact.bin"))
(call-with-output-file artifact
  (lambda (out) (write-bytes (make-bytes 100000 7) out)))

(define signature (sign-file artifact #:private-key priv))
(check-true (string? signature) "signature is base64 text")
(check-false (string-contains? signature "\n") "signature is single-line")
(check-true (verify-signature artifact
                              #:public-key pub
                              #:signature signature)
            "correct signature verifies")

;; empty artifact edge case
(define empty-artifact (build-path dir "empty.bin"))
(call-with-output-file empty-artifact (lambda (_) (void)))
(check-true (verify-signature empty-artifact
                              #:public-key pub
                              #:signature (sign-file empty-artifact #:private-key priv))
            "empty artifact roundtrip")

;; ---- tamper / wrong key ------------------------------------------------------

;; flipped content byte -> signature must fail (integrity)
(call-with-output-file artifact
  (lambda (out) (write-bytes (make-bytes 100000 8)))
  #:exists 'truncate)
(check-false (verify-signature artifact
                               #:public-key pub
                               #:signature signature)
             "tampered artifact fails signature")

;; restore, then assert the expected-digest gate raises on mismatch —
;; callers verify sha256 (from the manifest) before the signature
(call-with-output-file artifact
  (lambda (out) (write-bytes (make-bytes 100000 7) out))
  #:exists 'truncate)
(check-exn exn:fail?
           (lambda ()
             (verify-signature artifact
                               #:public-key pub
                               #:signature signature
                               #:expected-sha256 "00"))
           "sha256 mismatch raises (caller bug or active tampering)")
(check-true (verify-signature artifact
                              #:public-key pub
                              #:signature signature
                              #:expected-sha256 (sha256-file artifact))
            "matching expected sha256 verifies")

;; a signature from a DIFFERENT key must not verify (authenticity)
(define-values (other-priv other-pub)
  (signing-keygen #:private-key (build-path dir "other.pem")
                  #:public-key (build-path dir "other-pub.pem")))
(check-false (verify-signature artifact
                               #:public-key other-pub
                               #:signature signature)
             "signature does not verify under a different pinned key")
(check-true
 (verify-signature artifact
                   #:public-key pub
                   #:signature signature)
 "original pair still verifies after the wrong-key probe")

;; ---- keygen options ----------------------------------------------------------

(define-values (enc-priv enc-pub)
  (signing-keygen #:private-key (build-path dir "enc.pem")
                  #:public-key (build-path dir "enc-pub.pem")
                  #:password "test-password"))
(check-true (signing-key-password-encrypted? enc-priv)
            "password keygen wraps the private key")
(define enc-sig (sign-file artifact
                           #:private-key enc-priv
                           #:password "test-password"))
(check-true (verify-signature artifact
                              #:public-key enc-pub
                              #:signature enc-sig)
            "encrypted keypair signs (with password) and verifies")
;; an encrypted PEM's header is ENCRYPTED PRIVATE KEY — i.e. the key
;; material is not sitting on disk in plaintext
(check-true (string-contains? (file->string enc-priv) "ENCRYPTED PRIVATE KEY")
            "encrypted PEM header")
(check-false (signing-key-password-encrypted? priv)
             "default keygen stays unencrypted")

;; digests agree between the file and string forms
(check-equal? (sha256-file artifact) (sha256-string (file->bytes artifact))
              "sha256-file and sha256-string agree")

(delete-directory/files dir)
