#lang racket/base

;; Update artifact and manifest signing command ownership.

(require racket/file
         racket/string
         glaze/signing
         glaze/update)

(provide updater-sign-command
         updater-verify-command
         updater-keygen-command
         manifest-sign-command
         manifest-verify-command)

;; ---- updater artifact signing (Ed25519) -------------------------------------

(define (require-option-value who option args)
  (unless (pair? (cdr args))
    (error who "~a requires a value" option))
  (cadr args))

(define (updater-sign-command rest)
  (let loop ([args rest]
             [artifact #f]
             [key #f]
             [password #f]
             [out #f])
    (cond
      [(null? args)
       (unless (and artifact key out)
         (error
          'update-sign
          "usage: raco glaze update-sign --artifact <file> --key <private.pem> --out <signature.txt> [--password <pw>]"))
       (define sig (sign-file artifact #:private-key key #:password password))
       (with-output-to-file out (lambda () (displayln sig)) #:exists 'replace)
       (printf "signed ~a -> ~a\n" artifact out)]
      [(equal? (car args) "--artifact")
       (loop (cddr args) (require-option-value 'update-sign "--artifact" args) key password out)]
      [(equal? (car args) "--key")
       (loop (cddr args) artifact (require-option-value 'update-sign "--key" args) password out)]
      [(equal? (car args) "--password")
       (loop (cddr args) artifact key (require-option-value 'update-sign "--password" args) out)]
      [(equal? (car args) "--out")
       (loop (cddr args) artifact key password (require-option-value 'update-sign "--out" args))]
      [artifact (error 'update-sign "unexpected argument: ~a" (car args))]
      [else (loop (cdr args) (car args) key password out)])))

(define (updater-verify-command rest)
  (let loop ([args rest]
             [artifact #f]
             [pub #f]
             [signature #f]
             [sha256 #f])
    (cond
      [(null? args)
       (unless (and artifact pub signature)
         (error
          'update-verify
          "usage: raco glaze update-verify --artifact <file> --pub <public.pem> --signature <signature.txt|base64> [--sha256 <hex>]"))
       (define sig-text
         (if (file-exists? signature)
             (string-trim (file->string signature))
             signature))
       (printf "Verifying ~a...\n" artifact)
       (if (verify-signature artifact #:public-key pub #:signature sig-text #:expected-sha256 sha256)
           (begin
             (printf "VALID\n")
             (exit 0))
           (begin
             (printf "INVALID\n")
             (exit 1)))]
      [(equal? (car args) "--artifact")
       (loop (cddr args)
             (require-option-value 'update-verify "--artifact" args)
             pub
             signature
             sha256)]
      [(equal? (car args) "--pub")
       (loop (cddr args)
             artifact
             (require-option-value 'update-verify "--pub" args)
             signature
             sha256)]
      [(equal? (car args) "--signature")
       (loop (cddr args)
             artifact
             pub
             (require-option-value 'update-verify "--signature" args)
             sha256)]
      [(equal? (car args) "--sha256")
       (loop (cddr args)
             artifact
             pub
             signature
             (require-option-value 'update-verify "--sha256" args))]
      [artifact (error 'update-verify "unexpected argument: ~a" (car args))]
      [else (loop (cdr args) (car args) pub signature sha256)])))

(define (updater-keygen-command rest)
  (let loop ([args rest]
             [out "updater-keys"]
             [password #f])
    (cond
      [(null? args)
       (make-directory* out)
       (define-values (priv pub)
         (signing-keygen #:private-key (build-path out "private.pem")
                         #:public-key (build-path out "public.pem")
                         #:password password))
       (printf
        "Updater Ed25519 keypair written:\n  private: ~a  (keep secret — signs update artifacts)\n  public:  ~a  (pin inside the app — verifies update artifacts)\n"
        priv
        pub)
       (printf "public key fingerprint: ~a\n" (public-key-fingerprint pub))]
      [(equal? (car args) "--out")
       (loop (cddr args) (require-option-value 'updater-keygen "--out" args) password)]
      [(equal? (car args) "--password")
       (loop (cddr args) out (require-option-value 'updater-keygen "--password" args))]
      [else (error 'updater-keygen "unexpected argument: ~a" (car args))])))

(define (manifest-sign-command rest)
  (let loop ([args rest]
             [manifest-path #f]
             [key #f]
             [key-id #f]
             [password #f]
             [out #f])
    (cond
      [(null? args)
       (unless (and manifest-path key key-id out)
         (error
          'manifest-sign
          "usage: raco glaze manifest-sign --manifest <payload.json> --key <private.pem> --key-id <id> --out <signed.json> [--password <pw>]"))
       (define manifest (payload-bytes->update-manifest (file->bytes manifest-path)))
       (call-with-output-file
        out
        #:exists 'replace
        (lambda (output)
          (write-signed-update-manifest manifest key key-id output #:password password)))
       (printf "signed update manifest ~a -> ~a\n" manifest-path out)]
      [(equal? (car args) "--manifest")
       (loop (cddr args)
             (require-option-value 'manifest-sign "--manifest" args)
             key
             key-id
             password
             out)]
      [(equal? (car args) "--key")
       (loop (cddr args)
             manifest-path
             (require-option-value 'manifest-sign "--key" args)
             key-id
             password
             out)]
      [(equal? (car args) "--key-id")
       (loop (cddr args)
             manifest-path
             key
             (require-option-value 'manifest-sign "--key-id" args)
             password
             out)]
      [(equal? (car args) "--password")
       (loop (cddr args)
             manifest-path
             key
             key-id
             (require-option-value 'manifest-sign "--password" args)
             out)]
      [(equal? (car args) "--out")
       (loop (cddr args)
             manifest-path
             key
             key-id
             password
             (require-option-value 'manifest-sign "--out" args))]
      [else (error 'manifest-sign "unexpected argument: ~a" (car args))])))

(define (manifest-verify-command rest)
  (let loop ([args rest]
             [manifest-path #f]
             [public-key #f]
             [key-id #f])
    (cond
      [(null? args)
       (unless (and manifest-path public-key)
         (error
          'manifest-verify
          "usage: raco glaze manifest-verify --manifest <signed.json> --pub <public.pem> [--key-id <id>]"))
       (define manifest
         (call-with-input-file manifest-path
                               (lambda (input)
                                 (verify-signed-update-manifest input public-key #:key-id key-id))))
       (printf "VALID: ~a ~a (~a)\n"
               (update-manifest-application-id manifest)
               (update-manifest-version manifest)
               (update-manifest-channel manifest))]
      [(equal? (car args) "--manifest")
       (loop (cddr args) (require-option-value 'manifest-verify "--manifest" args) public-key key-id)]
      [(equal? (car args) "--pub")
       (loop (cddr args) manifest-path (require-option-value 'manifest-verify "--pub" args) key-id)]
      [(equal? (car args) "--key-id")
       (loop (cddr args)
             manifest-path
             public-key
             (require-option-value 'manifest-verify "--key-id" args))]
      [else (error 'manifest-verify "unexpected argument: ~a" (car args))])))
