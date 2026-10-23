#lang racket/base

;; Code signing and notarization for packaged distributions. Signing failures
;; abort the build — shipping an unsigned "signed" distribution is worse than
;; a failed build — while a missing toolchain degrades to a loud warning.

(require racket/file
         racket/system
         racket/list
         racket/path
         racket/port
         racket/string
         "build-tools.rkt")

(provide default-timestamp-url
         windows-cert-flag
         sign-dist
         sign-macos-bundle
         sign-windows-file
         notarize-macos)

(define default-timestamp-url "http://timestamp.digicert.com")

;; A 40-hex string is a SHA-1 thumbprint; anything else is a subject name.
(define (windows-cert-flag cert-spec)
  (if (regexp-match? #px"^[0-9a-fA-F]{40}$" cert-spec) "/sha1" "/n"))

;; Platform dispatch for #:sign. Aborts the build on signing failure; a
;; missing toolchain degrades to a loud warning (except codesign, which is
;; always present on macOS — a failure there is a real error).
(define (sign-dist os out-dir app-name sign entitlements hardened-runtime? timestamp-url)
  (case os
    [(macosx)
     (define bundle (build-path out-dir (string-append app-name ".app")))
     (unless (directory-exists? bundle)
       (error 'build-app "cannot sign: bundle not found at ~a" bundle))
     (sign-macos-bundle bundle sign entitlements hardened-runtime?)]
    [(windows)
     (define exe-path (build-path out-dir (string-append app-name ".exe")))
     (if (file-exists? exe-path)
         (sign-windows-file exe-path sign timestamp-url)
         (displayln (format "[glaze] cannot sign: exe not found at ~a" exe-path)
                    (current-error-port)))]
    [else
     (displayln "[glaze] --sign is not applicable on this platform (no standard signing "
                (current-error-port))
     (displayln "scheme for Linux apps); ignoring." (current-error-port))]))

;; Sign a macOS .app with `codesign`, then verify. Raises on failure.
;;
;; Nested code (the bundled Racket.framework and any dylibs) is signed
;; first, then the bundle itself WITHOUT --deep: one --deep pass can produce
;; Team-ID-mismatched nested signatures on Apple Silicon (dyld then refuses
;; to map the framework: "different Team IDs"). Entitlements apply to the
;; main executable only; the hardened-runtime option applies to all code
;; (notarization requires it everywhere).
(define (sign-macos-bundle bundle identity entitlements hardened-runtime?)
  (define codesign (find-executable-path "codesign" #f))
  (unless codesign
    (error 'build-app "codesign not found; cannot sign ~a" bundle))
  ;; Hardened runtime's library validation requires mapped libraries to
  ;; carry the same Team ID as the process — under an ad-hoc identity there
  ;; IS no Team ID, so the runtime option would make the app refuse its own
  ;; framework. Hardened runtime only matters for notarization, which needs
  ;; a real identity anyway; skip it for ad-hoc.
  (define hardened? (and hardened-runtime? (not (equal? identity "-"))))
  ;; codesign rewrites the main executable — make sure it is writable.
  (define main-exe (build-path bundle "Contents" "MacOS" (path->string (file-name-from-path bundle))))
  (when (file-exists? main-exe)
    (file-or-directory-permissions main-exe
                                   (bitwise-ior (file-or-directory-permissions main-exe 'bits)
                                                user-write-bit)))
  (define common-args
    (append (list "--force" "--sign" identity)
            (if hardened?
                (list "--options" "runtime")
                '())))
  ;; 1. nested libraries: frameworks ship as versioned dylibs that codesign
  ;;    may not recognize as bundles, so sign each file; non-code files
  ;;    fail harmlessly and are skipped.
  (define lib-dir (build-path bundle "Contents" "lib"))
  (when (directory-exists? lib-dir)
    (for ([p (in-directory lib-dir)]
          #:when (file-exists? p))
      (apply system*/exit-code codesign (append common-args (list (path->string p))))))
  ;; 2. the bundle itself: signs the main executable and seals resources.
  (define args
    (append common-args
            (if entitlements
                (list "--entitlements" (path->string (path->complete-path entitlements)))
                '())
            (list (path->string bundle))))
  (unless (zero? (apply system*/exit-code codesign args))
    (error 'build-app "codesign failed for ~a (identity ~a)" bundle identity))
  (unless (zero? (system*/exit-code codesign "--verify" "--strict" (path->string bundle)))
    (error 'build-app "codesign verify failed for ~a" bundle))
  (fprintf (current-error-port) "[glaze] signed: ~a (identity ~a)\n" bundle identity))

;; Sign a file (Windows exe/msi, or anything signtool accepts) with the
;; certificate identified by `cert-spec` — a SHA-1 thumbprint (40 hex chars)
;; or a certificate subject name. Uses an RFC-3161 timestamp so the
;; signature outlives the certificate. Warns and skips when signtool is not
;; installed; raises when signtool exists but signing fails.
(define (sign-windows-file file cert-spec [timestamp-url default-timestamp-url])
  (define signtool (find-tool "signtool.exe" "signtool"))
  (unless signtool
    (displayln "[glaze] signtool not found (Windows SDK); skipping code signing. "
               (current-error-port))
    (displayln "[glaze] Install the Windows SDK Signing Tools to sign for distribution."
               (current-error-port))
    #f)
  (when signtool
    (define cert-flag (windows-cert-flag cert-spec))
    (define args
      (append (list "sign" "/fd" "SHA256" cert-flag cert-spec)
              (if timestamp-url
                  (list "/tr" timestamp-url "/td" "SHA256")
                  '())
              (list (path->string (path->complete-path file)))))
    (unless (zero? (apply system*/exit-code (find-executable-path signtool #f) args))
      (error 'build-app "signtool failed for ~a" file))
    (fprintf (current-error-port) "[glaze] signed: ~a\n" file)
    #t))

;; Notarize the built dmg (or a zip of the .app when no dmg was produced)
;; via `xcrun notarytool --keychain-profile`, then staple the ticket.
;; Raises on failure — a failed notarization must not ship silently.
(define (notarize-macos os out-dir app-name keychain-profile)
  (unless (eq? os 'macosx)
    (displayln "[glaze] notarization only applies to macOS builds; ignoring." (current-error-port))
    #f)
  (when (eq? os 'macosx)
    (define dist (path->complete-path out-dir))
    (define dmg (build-path dist (string-append app-name ".dmg")))
    (define bundle (build-path dist (string-append app-name ".app")))
    (define xcrun (find-executable-path "xcrun" #f))
    (unless xcrun
      (error 'build-app "xcrun not found; cannot notarize"))
    (define artifact
      (if (file-exists? dmg)
          dmg
          ;; no dmg: notarytool needs an archive — zip the .app to a temp file
          (let ()
            (define zip (make-temporary-file "glaze-notarize-~a.zip"))
            (parameterize ([current-directory dist])
              (unless (zero? (system*/exit-code (find-executable-path "zip" #f)
                                                "-qr"
                                                (path->string zip)
                                                (string-append app-name ".app")))
                (error 'build-app "could not zip the .app for notarization")))
            zip)))
    (unless (zero? (system*/exit-code xcrun
                                      "notarytool"
                                      "submit"
                                      (path->string artifact)
                                      "--keychain-profile"
                                      keychain-profile
                                      "--wait"))
      (error 'build-app "notarization failed for ~a (profile ~a)" artifact keychain-profile))
    (define staple-target (if (file-exists? dmg) dmg bundle))
    (system*/exit-code xcrun "stapler" "staple" (path->string staple-target))
    (fprintf (current-error-port) "[glaze] notarized: ~a\n" staple-target)
    #t))
