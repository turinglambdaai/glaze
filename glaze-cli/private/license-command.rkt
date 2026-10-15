#lang racket/base

;; Offline product-license command ownership.

(require racket/file
         racket/list
         racket/system
         glaze/license)

(provide parse-keygen-opts
         keygen-command
         parse-license-opts
         license-command)

;; ---- keygen: create an RSA keypair for license signing ----

(define (parse-keygen-opts rest)
  (let loop ([args rest]
             [out "keys"])
    (cond
      [(null? args) out]
      [(and (equal? (car args) "--out") (pair? (cdr args))) (loop (cddr args) (cadr args))]
      [else (loop (cdr args) out)])))

(define (keygen-command rest)
  (define out (parse-keygen-opts rest))
  (define openssl (find-executable-path "openssl" #f))
  (unless openssl
    (error 'keygen "openssl not found on PATH"))
  (make-directory* out)
  (define priv (build-path out "private.pem"))
  (define pub (build-path out "public.pem"))
  (printf "Generating RSA-2048 keypair in ~a/...\n" out)
  (unless (zero? (system*/exit-code openssl
                                    "genpkey"
                                    "-algorithm"
                                    "RSA"
                                    "-pkeyopt"
                                    "rsa_keygen_bits:2048"
                                    "-out"
                                    (path->string priv)))
    (error 'keygen "openssl genpkey failed"))
  (unless (zero? (system*/exit-code openssl
                                    "pkey"
                                    "-in"
                                    (path->string priv)
                                    "-pubout"
                                    "-out"
                                    (path->string pub)))
    (error 'keygen "openssl pkey -pubout failed"))
  (printf
   "Done.\n  private: ~a  (keep secret — signs licenses)\n  public:  ~a  (ship with the app — verifies licenses)\n"
   priv
   pub))

;; ---- license: sign / verify license files ----

(define (parse-license-opts rest)
  (let loop ([args rest]
             [sub #f]
             [key #f]
             [pub #f]
             [product #f]
             [subject #f]
             [expiry #f]
             [machine #f]
             [out "app.license"]
             [positional '()])
    (cond
      [(null? args) (values sub key pub product subject expiry machine out (reverse positional))]
      [(and (not sub) (member (car args) '("sign" "verify")))
       (loop (cdr args) (car args) key pub product subject expiry machine out positional)]
      [(and (equal? (car args) "--key") (pair? (cdr args)))
       (loop (cddr args) sub (cadr args) pub product subject expiry machine out positional)]
      [(and (equal? (car args) "--pub") (pair? (cdr args)))
       (loop (cddr args) sub key (cadr args) product subject expiry machine out positional)]
      [(and (equal? (car args) "--product") (pair? (cdr args)))
       (loop (cddr args) sub key pub (cadr args) subject expiry machine out positional)]
      [(and (equal? (car args) "--subject") (pair? (cdr args)))
       (loop (cddr args) sub key pub product (cadr args) expiry machine out positional)]
      [(and (equal? (car args) "--expiry") (pair? (cdr args)))
       (loop (cddr args) sub key pub product subject (cadr args) machine out positional)]
      [(and (equal? (car args) "--machine-id") (pair? (cdr args)))
       (loop (cddr args) sub key pub product subject expiry (cadr args) out positional)]
      [(equal? (car args) "--machine-id")
       (loop (cdr args) sub key pub product subject expiry (machine-id) out positional)]
      [(and (equal? (car args) "--out") (pair? (cdr args)))
       (loop (cddr args) sub key pub product subject expiry machine (cadr args) positional)]
      [else
       (loop (cdr args)
             sub
             key
             pub
             product
             subject
             expiry
             machine
             out
             (cons (car args) positional))])))

(define (license-command rest)
  (define-values (sub key pub product subject expiry machine out positional)
    (parse-license-opts rest))
  (case sub
    [("sign")
     (unless (and key product subject)
       (error
        'license
        "usage: raco glaze license sign --key <private.pem> --product <name> --subject <who> [--expiry YYYY-MM-DD] [--machine-id] --out <file>"))
     ;; --machine-id accepts the raw OS machine identifier or the (machine-id)
     ;; digest; validate-license compares against the digest, so a raw value
     ;; must be normalized here or the license could never verify on the
     ;; target machine.
     (define machine*
       (and machine
            (if (regexp-match? #px"^[0-9a-fA-F]{64}$" machine)
                machine
                (sha256-hex (string->bytes/utf-8 machine)))))
     (issue-license #:private-key key
                    #:product product
                    #:subject subject
                    #:expiry expiry
                    #:machine-id machine*
                    #:out out)
     (printf "License written: ~a\n" out)]
    [("verify")
     (unless (and pub product (pair? positional))
       (error 'license
              "usage: raco glaze license verify --pub <public.pem> --product <name> <file.license>"))
     (define r (validate-license (last positional) #:public-key pub #:product product))
     (if (hash-ref r 'valid)
         (begin
           (printf "VALID\n  subject: ~a\n  expiry: ~a\n  machine-id: ~a\n"
                   (hash-ref r 'subject)
                   (or (hash-ref r 'expiry) "(no expiry)")
                   (or (hash-ref r 'machine-id) "(not machine-bound)")))
         (printf "INVALID (reason: ~a)\n" (hash-ref r 'reason)))
     (unless (hash-ref r 'valid)
       (exit 1))]
    [else
     (displayln "usage: raco glaze license sign|verify [options]")
     (displayln "  sign:   --key <private.pem> --product <name> --subject <who>")
     (displayln "          [--expiry YYYY-MM-DD] [--machine-id | --machine-id <hex>] --out <file>")
     (displayln "  verify: --pub <public.pem> --product <name> <file.license>")]))
