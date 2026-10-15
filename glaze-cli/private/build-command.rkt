#lang racket/base

;; CLI ownership for distribution build options. Platform staging, signing,
;; and installers remain in glaze/build; this module only parses one command
;; and calls that stable boundary.

(require racket/match
         glaze/build
         glaze-cli/private/project)

(provide parse-build-opts
         parse-installer-assets
         build-command)

;; Parse the rest args for `build`. Recognized flags:
;;   --name <name>        app/bundle name (default: project dir name)
;;   --version <v>        app version (Info.plist / MSI ProductVersion)
;;   --publisher <name>   human-readable native installer publisher
;;   --identifier <id>    stable package identifier used for upgrades/uninstall
;;   --icon <path>        .ico (Windows) / .icns (macOS)
;;   --entry <path>       entry file (default: main.rkt)
;;   --out <dir>          output directory (default: dist)
;;   --embed-dlls         Windows: embed DLLs into a single .exe
;;   --installer          also build a platform installer
;;   --sign <id>          code-signing identity (macOS: codesign identity,
;;                        "-" = ad-hoc; Windows: cert SHA-1 thumbprint or
;;                        subject name for signtool)
;;   --entitlements <p>   macOS: path to a .entitlements plist
;;   --no-hardened-runtime  macOS: disable hardened runtime
;;   --timestamp-url <u>  Windows: RFC-3161 timestamp server for signtool
;;   --notarize <profile> macOS: notarytool keychain profile
;;   --url-scheme <name>  deep-link URL scheme (repeatable)
;;   --dmg-background <p>         macOS: branded DMG background .png
;;   --installer-license <p>      Windows: .rtf for the MSI license page
;;   --installer-banner <p>       Windows: 493x58 .bmp wizard banner
;;   --installer-dialog <p>       Windows: 493x312 .bmp wizard dialog
(define (parse-build-opts rest)
  ;; Extract installer identity separately so the established positional
  ;; parser below stays backward compatible and these options can appear in
  ;; any order.
  (define-values (publisher identifier filtered-rest)
    (let extract ([args rest]
                  [publisher #f]
                  [identifier #f]
                  [kept '()])
      (match args
        [(list* "--publisher" value more) (extract more value identifier kept)]
        [(list* "--identifier" value more) (extract more publisher value kept)]
        ;; The installer asset flags parse separately (parse-installer-assets);
        ;; swallow them and their values here so the positional loop below
        ;; never sees them.
        [(list* "--dmg-background" _ more) (extract more publisher identifier kept)]
        [(list* "--installer-license" _ more) (extract more publisher identifier kept)]
        [(list* "--installer-banner" _ more) (extract more publisher identifier kept)]
        [(list* "--installer-dialog" _ more) (extract more publisher identifier kept)]
        [(cons value more) (extract more publisher identifier (cons value kept))]
        ['() (values publisher identifier (reverse kept))])))
  (let loop ([args filtered-rest]
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
       (values name
               version
               icon
               entry
               out
               embed
               installer
               sign
               entitlements
               no-hardened
               ts-url
               notarize
               (reverse schemes)
               publisher
               identifier)]
      [(and (equal? (car args) "--name") (pair? (cdr args)))
       (loop (cddr args)
             (cadr args)
             version
             icon
             entry
             out
             embed
             installer
             sign
             entitlements
             no-hardened
             ts-url
             notarize
             schemes)]
      [(and (equal? (car args) "--version") (pair? (cdr args)))
       (loop (cddr args)
             name
             (cadr args)
             icon
             entry
             out
             embed
             installer
             sign
             entitlements
             no-hardened
             ts-url
             notarize
             schemes)]
      [(and (equal? (car args) "--icon") (pair? (cdr args)))
       (loop (cddr args)
             name
             version
             (cadr args)
             entry
             out
             embed
             installer
             sign
             entitlements
             no-hardened
             ts-url
             notarize
             schemes)]
      [(and (equal? (car args) "--entry") (pair? (cdr args)))
       (loop (cddr args)
             name
             version
             icon
             (cadr args)
             out
             embed
             installer
             sign
             entitlements
             no-hardened
             ts-url
             notarize
             schemes)]
      [(and (equal? (car args) "--out") (pair? (cdr args)))
       (loop (cddr args)
             name
             version
             icon
             entry
             (cadr args)
             embed
             installer
             sign
             entitlements
             no-hardened
             ts-url
             notarize
             schemes)]
      [(equal? (car args) "--embed-dlls")
       (loop (cdr args)
             name
             version
             icon
             entry
             out
             #t
             installer
             sign
             entitlements
             no-hardened
             ts-url
             notarize
             schemes)]
      [(equal? (car args) "--installer")
       (loop (cdr args)
             name
             version
             icon
             entry
             out
             embed
             #t
             sign
             entitlements
             no-hardened
             ts-url
             notarize
             schemes)]
      [(and (equal? (car args) "--sign") (pair? (cdr args)))
       (loop (cddr args)
             name
             version
             icon
             entry
             out
             embed
             installer
             (cadr args)
             entitlements
             no-hardened
             ts-url
             notarize
             schemes)]
      [(and (equal? (car args) "--entitlements") (pair? (cdr args)))
       (loop (cddr args)
             name
             version
             icon
             entry
             out
             embed
             installer
             sign
             (cadr args)
             no-hardened
             ts-url
             notarize
             schemes)]
      [(equal? (car args) "--no-hardened-runtime")
       (loop (cdr args)
             name
             version
             icon
             entry
             out
             embed
             installer
             sign
             entitlements
             #t
             ts-url
             notarize
             schemes)]
      [(and (equal? (car args) "--timestamp-url") (pair? (cdr args)))
       (loop (cddr args)
             name
             version
             icon
             entry
             out
             embed
             installer
             sign
             entitlements
             no-hardened
             (cadr args)
             notarize
             schemes)]
      [(and (equal? (car args) "--notarize") (pair? (cdr args)))
       (loop (cddr args)
             name
             version
             icon
             entry
             out
             embed
             installer
             sign
             entitlements
             no-hardened
             ts-url
             (cadr args)
             schemes)]
      [(and (equal? (car args) "--url-scheme") (pair? (cdr args)))
       (loop (cddr args)
             name
             version
             icon
             entry
             out
             embed
             installer
             sign
             entitlements
             no-hardened
             ts-url
             notarize
             (cons (cadr args) schemes))]
      [else
       (printf "Warning: ignoring unknown build argument: ~a\n" (car args))
       (loop (cdr args)
             name
             version
             icon
             entry
             out
             embed
             installer
             sign
             entitlements
             no-hardened
             ts-url
             notarize
             schemes)])))

;; The four installer asset flags use the same out-of-order extraction so
;; they compose with every existing option.
(define (parse-installer-assets rest)
  (let extract ([args rest]
                [bg #f]
                [license #f]
                [banner #f]
                [dialog #f])
    (match args
      [(list* "--dmg-background" value more) (extract more value license banner dialog)]
      [(list* "--installer-license" value more) (extract more bg value banner dialog)]
      [(list* "--installer-banner" value more) (extract more bg license value dialog)]
      [(list* "--installer-dialog" value more) (extract more bg license banner value)]
      [(cons _ more) (extract more bg license banner dialog)]
      ['() (values bg license banner dialog)])))

(define (build-command rest)
  (define-values (name
                  version
                  icon
                  entry
                  out
                  embed
                  installer
                  sign
                  entitlements
                  no-hardened
                  ts-url
                  notarize
                  schemes
                  publisher
                  identifier)
    (parse-build-opts rest))
  (define-values (dmg-background installer-license installer-banner installer-dialog)
    (parse-installer-assets rest))
  (define schema-state (hash-ref (project-schema-status) 'status))
  (unless (equal? schema-state "ready")
    (printf "Warning: project schema is ~a; run `raco glaze schema write` before release.\n"
            schema-state))
  (printf "Building Glaze app (entry=~a, name=~a)...\n" entry (or name "<project dir>"))
  (define dist-path
    (build-app #:entry entry
               #:name name
               #:version version
               #:publisher publisher
               #:identifier identifier
               #:icon icon
               #:out-dir out
               #:embed-dlls? embed
               #:installer? installer
               #:sign sign
               #:entitlements entitlements
               #:no-hardened-runtime? no-hardened
               #:timestamp-url ts-url
               #:notarize-profile notarize
               #:url-schemes schemes
               #:dmg-background dmg-background
               #:installer-license installer-license
               #:installer-banner installer-banner
               #:installer-dialog installer-dialog))
  (printf "Done. Distribution in: ~a\n" dist-path))
