#lang racket/base

(require racket/list
         racket/match
         racket/file
         racket/string
         racket/system
         glaze/server
         glaze/browser
         glaze/build
         glaze/license)

(define (init-project name)
  (printf "Creating Glaze project: ~a\n" name)
  (make-directory* name)
  (make-directory* (build-path name "public"))
  (write-file (build-path name "main.rkt")
              (string-append "#lang racket/base\n\n"
                             "(require racket/runtime-path\n"
                             "         glaze)\n\n"
                             "(define-runtime-path public \"public\")\n\n"
                             "(module+ main\n"
                             "  (run-app #:public-dir public\n"
                             "           #:title \"Glaze App\"))\n"))
  (write-file
   (build-path name "public" "index.html")
   #"<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Glaze App</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; background: #0f0f0f; color: #e0e0e0;
    }
    h1 { font-size: 2.5rem; font-weight: 300; }
    p { margin-top: 0.5rem; color: #888; }
    code { background: #1a1a2e; padding: 0.2rem 0.5rem; border-radius: 4px; }
  </style>
</head>
<body>
  <div style=\"text-align:center\">
    <h1>Glaze works!</h1>
    <p>Edit <code>public/index.html</code> to get started.</p>
  </div>
</body>
</html>
")
  (printf "Done! Run:\n  cd ~a\n  racket main.rkt\n" name))

(define (dev-server)
  (define-values (actual-port server) (start-dev-server #:port 8080 #:public-dir "public"))
  (printf "Dev server running at http://127.0.0.1:~a\n" actual-port)
  (open-browser (format "http://127.0.0.1:~a" actual-port))
  (with-handlers ([exn:break? (lambda (e)
                                (stop-server server)
                                (printf "Server stopped.\n"))])
    (sync never-evt)))

;; Parse the rest args for `build`. Recognized flags:
;;   --name <name>        app/bundle name (default: project dir name)
;;   --version <v>        app version (Info.plist / MSI ProductVersion)
;;   --icon <path>        .ico (Windows) / .icns (macOS)
;;   --entry <path>       entry file (default: main.rkt)
;;   --out <dir>          output directory (default: dist)
;;   --embed-dlls         Windows: embed DLLs into a single .exe
;;   --installer          also build a platform installer
;;   --sign <id>          code-signing identity (macOS: codesign identity,
;;                        "-" = ad-hoc; Windows: cert SHA-1 thumbprint or
;;                        subject name for signtool)
;;   --entitlements <p>   macOS: .entitlements plist for codesign
;;   --no-hardened-runtime  macOS: disable hardened runtime (notarization
;;                        needs it; leave it on unless you know better)
;;   --timestamp-url <u>  Windows: RFC-3161 timestamp server for signtool
;;   --notarize <profile> macOS: notarytool keychain profile; submits the
;;                        dmg/app for notarization and staples it
;;   --url-scheme <name>  register a custom URL scheme (repeatable)
(define (parse-build-opts rest)
  (let loop ([args rest]
             [name #f]
             [version #f]
             [icon #f]
             [entry "main.rkt"]
             [out "dist"]
             [embed #f]
             [installer #f]
             [sign #f]
             [entitlements #f]
             [no-hardened #f]
             [ts-url #f]
             [notarize #f]
             [schemes '()])
    (cond
      [(null? args)
       (values name version icon entry out embed installer
               sign entitlements no-hardened ts-url notarize (reverse schemes))]
      [(and (equal? (car args) "--name") (pair? (cdr args)))
       (loop (cddr args) (cadr args) version icon entry out embed installer
             sign entitlements no-hardened ts-url notarize schemes)]
      [(and (equal? (car args) "--version") (pair? (cdr args)))
       (loop (cddr args) name (cadr args) icon entry out embed installer
             sign entitlements no-hardened ts-url notarize schemes)]
      [(and (equal? (car args) "--icon") (pair? (cdr args)))
       (loop (cddr args) name version (cadr args) entry out embed installer
             sign entitlements no-hardened ts-url notarize schemes)]
      [(and (equal? (car args) "--entry") (pair? (cdr args)))
       (loop (cddr args) name version icon (cadr args) out embed installer
             sign entitlements no-hardened ts-url notarize schemes)]
      [(and (equal? (car args) "--out") (pair? (cdr args)))
       (loop (cddr args) name version icon entry (cadr args) embed installer
             sign entitlements no-hardened ts-url notarize schemes)]
      [(equal? (car args) "--embed-dlls")
       (loop (cdr args) name version icon entry out #t installer
             sign entitlements no-hardened ts-url notarize schemes)]
      [(equal? (car args) "--installer")
       (loop (cdr args) name version icon entry out embed #t
             sign entitlements no-hardened ts-url notarize schemes)]
      [(and (equal? (car args) "--sign") (pair? (cdr args)))
       (loop (cddr args) name version icon entry out embed installer
             (cadr args) entitlements no-hardened ts-url notarize schemes)]
      [(and (equal? (car args) "--entitlements") (pair? (cdr args)))
       (loop (cddr args) name version icon entry out embed installer
             sign (cadr args) no-hardened ts-url notarize schemes)]
      [(equal? (car args) "--no-hardened-runtime")
       (loop (cdr args) name version icon entry out embed installer
             sign entitlements #t ts-url notarize schemes)]
      [(and (equal? (car args) "--timestamp-url") (pair? (cdr args)))
       (loop (cddr args) name version icon entry out embed installer
             sign entitlements no-hardened (cadr args) notarize schemes)]
      [(and (equal? (car args) "--notarize") (pair? (cdr args)))
       (loop (cddr args) name version icon entry out embed installer
             sign entitlements no-hardened ts-url (cadr args) schemes)]
      [(and (equal? (car args) "--url-scheme") (pair? (cdr args)))
       (loop (cddr args) name version icon entry out embed installer
             sign entitlements no-hardened ts-url notarize
             (cons (cadr args) schemes))]
      [else
       (printf "Warning: ignoring unknown build argument: ~a\n" (car args))
       (loop (cdr args) name version icon entry out embed installer
             sign entitlements no-hardened ts-url notarize schemes)])))

(define (build-command rest)
  (define-values (name version icon entry out embed installer
                 sign entitlements no-hardened ts-url notarize schemes)
    (parse-build-opts rest))
  (printf "Building Glaze app (entry=~a, name=~a)...\n" entry (or name "<project dir>"))
  (define dist-path
    (build-app #:entry entry
               #:name name
               #:version version
               #:icon icon
               #:out-dir out
               #:embed-dlls? embed
               #:installer? installer
               #:sign sign
               #:entitlements entitlements
               #:no-hardened-runtime? no-hardened
               #:timestamp-url ts-url
               #:notarize-profile notarize
               #:url-schemes schemes))
  (printf "Done. Distribution in: ~a\n" dist-path))

(define (print-help)
  (displayln "Usage: raco glaze <command> [args]")
  (displayln "")
  (displayln "Commands:")
  (displayln "  init <name>   Create a new Glaze project")
  (displayln "  dev           Start dev server with auto-open browser")
  (displayln "  build         Build a distributable (raco exe + raco distribute)")
  (displayln "  keygen        Create an RSA keypair for license signing")
  (displayln "  license       Sign or verify offline license files")
  (displayln "  help          Show this help")
  (displayln "")
  (displayln "build options:")
  (displayln "  --name <name>        app/bundle name (default: project dir)")
  (displayln "  --version <v>        app version (Info.plist / MSI metadata)")
  (displayln "  --icon <path>        .ico (Windows) / .icns (macOS)")
  (displayln "  --entry <path>       entry file (default: main.rkt)")
  (displayln "  --out <dir>          output directory (default: dist)")
  (displayln "  --embed-dlls         Windows: embed DLLs into a single .exe")
  (displayln "  --installer          Also build a platform installer (msi/dmg/AppImage);")
  (displayln "                       falls back to zip/tar.gz when the toolchain is absent")
  (displayln "  --sign <id>          Code-sign the app (macOS: codesign identity, \"-\" =")
  (displayln "                       ad-hoc; Windows: signtool cert SHA-1 or subject)")
  (displayln "  --entitlements <p>   macOS: .entitlements plist for codesign")
  (displayln "  --no-hardened-runtime  macOS: skip hardened runtime (notarization needs it)")
  (displayln "  --timestamp-url <u>  Windows: RFC-3161 timestamp server for signtool")
  (displayln "  --notarize <profile> macOS: notarize + staple via notarytool keychain profile")
  (displayln "  --url-scheme <name>  Deep-link URL scheme (repeatable): macOS gets")
  (displayln "                       Info.plist entries; call (ensure-url-scheme! ...)")
  (displayln "                       at app start on Windows/Linux)"))


(define (write-file path content)
  (call-with-output-file path (lambda (out) (display content out)) #:exists 'replace))

;; ---- keygen: create an RSA keypair for license signing ----

;;   raco glaze keygen [--out <dir>]     ; writes private.pem + public.pem
(define (parse-keygen-opts rest)
  (let loop ([args rest] [out "keys"])
    (cond
      [(null? args) out]
      [(and (equal? (car args) "--out") (pair? (cdr args)))
       (loop (cddr args) (cadr args))]
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
  (unless (zero? (system*/exit-code openssl "genpkey" "-algorithm" "RSA"
                                     "-pkeyopt" "rsa_keygen_bits:2048"
                                     "-out" (path->string priv)))
    (error 'keygen "openssl genpkey failed"))
  (unless (zero? (system*/exit-code openssl "pkey" "-in" (path->string priv)
                                     "-pubout" "-out" (path->string pub)))
    (error 'keygen "openssl pkey -pubout failed"))
  (printf "Done.\n  private: ~a  (keep secret — signs licenses)\n  public:  ~a  (ship with the app — verifies licenses)\n"
          priv pub))

;; ---- license: sign / verify license files ----

(define (parse-license-opts rest)
  (let loop ([args rest]
             [sub #f]
             [key #f] [pub #f] [product #f] [subject #f]
             [expiry #f] [machine #f] [out "app.license"]
             [positional '()])
    (cond
      [(null? args)
       (values sub key pub product subject expiry machine out (reverse positional))]
      [(and (null? sub) (member (car args) '("sign" "verify")))
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
       (loop (cdr args) sub key pub product subject expiry machine out
             (cons (car args) positional))])))

(define (license-command rest)
  (define-values (sub key pub product subject expiry machine out positional)
    (parse-license-opts rest))
  (case sub
    [("sign")
     (unless (and key product subject)
       (error 'license "usage: raco glaze license sign --key <private.pem> --product <name> --subject <who> [--expiry YYYY-MM-DD] [--machine-id] --out <file>"))
     (issue-license #:private-key key
                    #:product product
                    #:subject subject
                    #:expiry expiry
                    #:machine-id machine
                    #:out out)
     (printf "License written: ~a\n" out)]
    [("verify")
     (unless (and pub product (pair? positional))
       (error 'license "usage: raco glaze license verify --pub <public.pem> --product <name> <file.license>"))
     (define r (validate-license (last positional) #:public-key pub #:product product))
     (if (hash-ref r 'valid)
         (begin
           (printf "VALID\n  subject: ~a\n  expiry: ~a\n  machine-id: ~a\n"
                   (hash-ref r 'subject)
                   (or (hash-ref r 'expiry) "(no expiry)")
                   (or (hash-ref r 'machine-id) "(not machine-bound)")))
         (printf "INVALID (reason: ~a)\n" (hash-ref r 'reason)))
     (unless (hash-ref r 'valid) (exit 1))]
    [else
     (displayln "usage: raco glaze license sign|verify [options]")
     (displayln "  sign:   --key <private.pem> --product <name> --subject <who>")
     (displayln "          [--expiry YYYY-MM-DD] [--machine-id | --machine-id <hex>] --out <file>")
     (displayln "  verify: --pub <public.pem> --product <name> <file.license>")]))

;; Dispatch CLI commands
(define args (vector->list (current-command-line-arguments)))
(cond
  [(null? args) (print-help)]
  [else
   (define cmd (car args))
   (define rest (cdr args))
   (match cmd
     ["init"
      (init-project (if (null? rest)
                        "myapp"
                        (car rest)))]
     ["dev" (dev-server)]
     ["build" (build-command rest)]
     ["keygen" (keygen-command rest)]
     ["license" (license-command rest)]
     ["help" (print-help)]
     [_
      (printf "Unknown command: ~a\n" cmd)
      (print-help)])])
