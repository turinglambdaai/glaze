#lang racket/base

;; App packaging helpers used by `raco glaze build`. Wraps `raco exe` and
;; `raco distribute` so a Glaze project becomes a runnable directory (Windows)
;; or application bundle (macOS) with its frontend assets bundled.
;;
;; The frontend (public/) is declared via define-runtime-path in the generated
;; entry module, so raco distribute copies it next to the executable; at
;; runtime the app resolves the directory without depending on the working
;; directory.
;;
;; This module is the build-graph orchestrator: it owns entry generation, the
;; raco exe/distribute invocation, and the public/ staging contract. Platform
;; staging, signing, and installer formats live in their own private owners
;; (macos-bundle, code-sign, windows-installer, linux-package,
;; archive-fallback); this module never reaches into their internals and they
;; never import this one.

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "private/build-entry.rkt"
         "private/build-tools.rkt"
         "private/code-sign.rkt"
         "private/linux-package-metadata.rkt"
         "private/linux-package.rkt"
         "private/macos-bundle.rkt"
         "private/windows-installer.rkt")

(provide build-app
         default-entry-template
         platform-backend-modules
         make-linux-installer
         deb-arch-name
         rpm-arch-name
         sanitize-package-name
         sanitize-package-version
         desktop-entry
         deb-control
         rpm-spec
         icon-png-bytes)

;; Modules that glaze's webview/sys/tray schedulers reach only via runtime
;; dispatch (dynamic-require keyed on (system-type 'os)). raco exe's static
;; module walk cannot see them, so an embedded/packaged build ships WITHOUT
;; the platform backend unless it is embedded explicitly with `++lib` — the
;; app would start and pass every headless check, then die at the first
;; window/notification with "collection not found". Builds always run on the
;; target platform, so keying on (system-type 'os) here is exact.
(define (platform-backend-modules)
  (define os (system-type 'os))
  (list (case os
          [(windows) 'glaze/webview/webview-windows]
          [(macosx) 'glaze/webview/webview-macos]
          [(unix) 'glaze/webview/webview-linux]
          [else 'glaze/webview/webview-stub])
        (case os
          [(windows) 'glaze/sys/sys-windows]
          [(macosx) 'glaze/sys/sys-macos]
          [(unix) 'glaze/sys/sys-linux]
          [else 'glaze/sys/sys-stub])
        (case os
          [(windows) 'glaze/tray/tray-windows]
          [(macosx) 'glaze/tray/tray-macos]
          [(unix) 'glaze/tray/tray-linux]
          [else 'glaze/tray/tray-stub])))

;; Build a Glaze project into a distributable.
;;
;;   #:entry    — the project's main.rkt path (default "main.rkt")
;;   #:name     — app name (default: entry's directory name)
;;   #:version  — app version string; goes into the macOS Info.plist
;;                (CFBundleShortVersionString / CFBundleVersion) and the
;;                Windows MSI ProductVersion (default "0.0.0")
;;   #:publisher — human-readable publisher used by native installers
;;   #:identifier — stable application/package identifier used to derive
;;                  Windows upgrade and uninstall identities
;;   #:icon     — optional .ico (Windows) / .icns (macOS)
;;   #:out-dir  — output directory for the distribution (default "dist")
;;   #:embed-dlls? — Windows only: embed DLLs into a single .exe (default #f)
;;   #:sign     — code-signing identity / certificate spec:
;;                macOS: a codesign identity ("-" for ad-hoc, or
;;                  "Developer ID Application: ...")
;;                Windows: a certificate SHA-1 thumbprint (40 hex chars) or
;;                  subject name for signtool
;;                Linux: signing is not standard; the flag is ignored with a
;;                  warning
;;   #:entitlements — macOS only: path to a .entitlements plist
;;   #:no-hardened-runtime? — macOS only: skip `--options runtime`
;;                  (hardened runtime is on by default; notarization
;;                  requires it)
;;   #:timestamp-url — Windows only: RFC-3161 timestamp server for
;;                  signtool (default: DigiCert public TSA)
;;   #:notarize-profile — macOS only: a `notarytool` keychain profile name;
;;                  submits the built dmg (or a zip of the .app) for
;;                  notarization and staples the result
;;   #:url-schemes — list of URL scheme names ("myapp"); macOS gets
;;                  CFBundleURLTypes in the bundle's Info.plist; on
;;                  Windows/Linux call (ensure-url-scheme! ...) at app
;;                  start to register the handler
;;   #:dmg-background — macOS only: project-relative or absolute .png shown
;;                  as the DMG window background; declaring it switches the
;;                  DMG to the branded drag-to-install layout (Applications
;;                  symlink, fixed 660x400 window, both icons placed).
;;                  Render at 1320x800 with 144dpi metadata so the natural
;;                  point size matches the window.
;;   #:installer-license — Windows only: .rtf shown on the MSI wizard's
;;                  license page; without it the repository LICENSE text
;;                  renders into RTF automatically
;;   #:installer-banner / #:installer-dialog — Windows only: .bmp artwork
;;                  for the MSI wizard (493x58 and 493x312)
;;
;; Returns the path to the produced distribution directory.
(define (build-app #:entry [entry "main.rkt"]
                   #:name [name #f]
                   #:version [version #f]
                   #:publisher [publisher #f]
                   #:identifier [identifier #f]
                   #:icon [icon #f]
                   #:out-dir [out-dir "dist"]
                   #:embed-dlls? [embed-dlls? #f]
                   #:installer? [installer? #f]
                   #:sign [sign #f]
                   #:entitlements [entitlements #f]
                   #:no-hardened-runtime? [no-hardened-runtime? #f]
                   #:timestamp-url [timestamp-url #f]
                   #:notarize-profile [notarize-profile #f]
                   #:url-schemes [url-schemes '()]
                   #:dmg-background [dmg-background #f]
                   #:installer-license [installer-license #f]
                   #:installer-banner [installer-banner #f]
                   #:installer-dialog [installer-dialog #f])
  (define entry-path
    (if (path? entry)
        entry
        (string->path entry)))
  (define out-dir-path
    (if (path? out-dir)
        out-dir
        (string->path out-dir)))
  (define icon-path
    (and icon
         (if (path? icon)
             icon
             (string->path icon))))
  (unless (file-exists? entry-path)
    (error 'build-app "entry file not found: ~a" entry-path))
  (define entry-abs (path->complete-path entry-path))
  (define project-dir (path-only entry-abs))
  (define app-name (or name (path->string (file-name-from-path project-dir))))
  (define app-publisher (or publisher app-name))
  (define app-identifier (or identifier app-name))
  (unless (and (string? app-publisher) (not (string=? (string-trim app-publisher) "")))
    (raise-argument-error 'build-app "non-empty string" app-publisher))
  (unless (and (string? app-identifier)
               (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._-]*$" app-identifier))
    (raise-argument-error
     'build-app
     "application identifier containing letters, digits, dot, underscore, or hyphen"
     app-identifier))

  ;; Generate an entry wrapper in a temp location that requires the user's
  ;; main plus glaze, and re-exports nothing. We write it next to the entry so
  ;; define-runtime-path for public/ resolves relative to the project.
  (define gen-entry (build-path project-dir "glaze-build-entry.rkt"))
  (call-with-output-file gen-entry
                         (lambda (out) (display (entry-module-source entry-path) out))
                         #:exists 'replace)

  ;; Assemble the raco exe arguments.
  (define os (system-type 'os))
  (define out-exe-name
    (case os
      [(windows) (string-append app-name ".exe")]
      [(macosx) app-name] ; --gui produces a .app bundle named app-name
      [else app-name]))
  (define out-exe-path (build-path project-dir out-exe-name))

  (define exe-args
    ;; --gui is Windows-only (console-less exe). On macOS --gui would make
    ;; raco exe emit an .app bundle directly, which raco distribute cannot
    ;; consume; the documented flow is a bare executable, which distribute
    ;; wraps into dist/<name>.app itself.
    (append (list "exe")
            (if (eq? os 'windows)
                (list "--gui")
                '())
            (if (and (eq? os 'windows) embed-dlls?)
                (list "--embed-dlls")
                '())
            (if icon-path
                (case os
                  [(windows) (list "--ico" (path->string icon-path))]
                  [(macosx) (list "--icns" (path->string icon-path))]
                  [else '()])
                '())
            ;; Embed the runtime-dispatched platform backends; see
            ;; platform-backend-modules for why this is load-bearing.
            (append* (for/list ([mod (in-list (platform-backend-modules))])
                       (list "++lib" (symbol->string mod))))
            (list "-o" (path->string out-exe-path) (path->string gen-entry))))

  (unless (apply system* (find-racket-bin) exe-args)
    (delete-the-generated-entry gen-entry)
    (error 'build-app "raco exe failed"))

  ;; raco exe emits a read-only launcher; `raco distribute` needs to rewrite
  ;; the copy it makes (Mach-O/ELF segment patching) and fails with EACCES
  ;; on some Racket versions otherwise.
  (file-or-directory-permissions out-exe-path
                                 (bitwise-ior (file-or-directory-permissions out-exe-path 'bits)
                                              user-write-bit))

  ;; Distribute. On Windows --embed-dlls already yields a near-standalone exe,
  ;; but we still run distribute to collect any remaining runtime files and to
  ;; produce a consistent layout across platforms.
  (define dist-args (list "distribute" (path->string out-dir-path) (path->string out-exe-path)))
  (unless (apply system* (find-racket-bin) dist-args)
    (delete-the-generated-entry gen-entry)
    (error 'build-app "raco distribute failed"))

  ;; Clean up the generated entry and the standalone exe copy (distribute has
  ;; its own copy inside out-dir).
  (delete-the-generated-entry gen-entry)
  (when (file-exists? out-exe-path)
    (delete-file out-exe-path))

  ;; macOS: `raco distribute` of a bare exe yields a flat bin/+lib/ layout
  ;; (exact shape varies across Racket versions) — assemble the canonical
  ;; .app bundle ourselves so Info.plist versioning, icons, dmg, and code
  ;; signing all have a bundle to work with.
  (when (eq? os 'macosx)
    (assemble-macos-bundle out-dir-path app-name (or version "0.0.0") url-schemes))

  ;; Bundle the project's public/ next to the distribution so the packaged
  ;; app can serve its frontend. On macOS the assets go inside the .app bundle
  ;; Resources; elsewhere they sit beside the executable. The generated entry
  ;; sets current-directory to the executable's dir at runtime so the user's
  ;; relative #:public-dir "public" resolves to this copy.
  (copy-public-into-dist project-dir out-dir-path app-name os)

  ;; Windows: WebView2Loader.dll is loaded through an absolute runtime path
  ;; inside the package tree, which raco distribute cannot trace, so a
  ;; packaged app would otherwise ship without its WebView loader (and the
  ;; MSI would harvest the same hole). Stage it beside the executable —
  ;; LoadLibrary probes the exe directory — before any installer is built.
  (when (eq? os 'windows)
    (define loader-src (collection-file-path "WebView2Loader.dll" "glaze" "native" "win-x64"))
    (copy-file loader-src (build-path out-dir-path "WebView2Loader.dll") #t))

  ;; macOS post-processing: customize the bundle's Info.plist if produced.
  (when (eq? os 'macosx)
    (post-process-macos-bundle out-dir-path app-name icon-path version))

  ;; Sign before installers: the macOS dmg wraps the signed .app and the
  ;; Windows msi embeds the signed exe. Signing failures abort the build
  ;; (shipping an unsigned "signed" dist is worse than a failed build);
  ;; a missing TOOL degrades with a warning, matching the installer steps.
  (when sign
    (sign-dist os out-dir-path app-name sign entitlements (not no-hardened-runtime?) timestamp-url))

  ;; Optional installer step. Each platform helper probes for the required
  ;; external tooling and warns (without failing the build) when it's absent;
  ;; the CI matrix installs them. Returns the produced artifact path (or #f).
  (define (asset-path value who)
    (and value
         (let ([path (if (path? value)
                         value
                         (string->path value))])
           (unless (absolute-path? path)
             (set! path (simple-form-path (build-path project-dir path))))
           (unless (file-exists? path)
             (error 'build-app "~a asset not found: ~a" who path))
           path)))
  (define installer-artifact
    (if installer?
        (make-installer os
                        out-dir-path
                        app-name
                        (or version "0.0.0")
                        app-publisher
                        app-identifier
                        project-dir
                        (asset-path dmg-background 'dmg-background)
                        (asset-path installer-license 'installer-license)
                        (asset-path installer-banner 'installer-banner)
                        (asset-path installer-dialog 'installer-dialog))
        #f))

  ;; Sign the installer artifact too (Windows msi / NSIS setup exe) — it
  ;; embeds the already-signed exe but is itself what SmartScreen judges.
  (when (and sign installer-artifact (eq? os 'windows))
    (sign-windows-file installer-artifact sign timestamp-url))

  ;; Notarize + staple (macOS only; needs a signed app and an Apple
  ;; notarytool keychain profile).
  (when notarize-profile
    (notarize-macos os out-dir-path app-name notarize-profile))

  (path->complete-path (build-path out-dir-path)))

;; ---- Installer helpers ----
;; Each tries the best-available native installer tool and degrades to a plain
;; archive (.zip / .tar.gz) when the tool is missing, printing a warning so the
;; caller knows an installer wasn't produced. Returns the produced artifact
;; path, or #f when nothing could be produced. The per-platform builders and
;; their toolchain staging live in the private installer owners.
(define (make-installer os
                        out-dir
                        app-name
                        version
                        publisher
                        identifier
                        project-dir
                        dmg-background
                        installer-license
                        installer-banner
                        installer-dialog)
  (case os
    [(windows)
     (make-windows-installer out-dir
                             app-name
                             version
                             publisher
                             identifier
                             #:project-dir project-dir
                             #:license-rtf installer-license
                             #:banner-bmp installer-banner
                             #:dialog-bmp installer-dialog)]
    [(macosx) (make-macos-installer out-dir app-name dmg-background)]
    [else (make-linux-installer out-dir app-name version publisher identifier)]))

;; Copy the project's public/ into the distribution next to the executable.
;; On macOS, assets live in <app>.app/Contents/Resources/public; elsewhere in
;; <dist>/public. The generated entry sets current-directory to the exe's dir
;; so a relative #:public-dir "public" finds this copy. (macOS uses Resources
;; so bundle-relative code can find it; the entry sets CWD there too.)
(define (copy-public-into-dist project-dir out-dir app-name os)
  (define src-public (build-path project-dir "public"))
  (when (directory-exists? src-public)
    (define dest-public
      (if (eq? os 'macosx)
          (build-path out-dir (string-append app-name ".app") "Contents" "Resources" "public")
          (build-path out-dir "public")))
    ;; copy-directory/files creates the dest itself but needs the parent
    ;; chain (a fresh .app from raco distribute may not have Resources/),
    ;; and fails if the dest already exists — remove a stale copy first.
    (make-directory* (path-only dest-public))
    (when (directory-exists? dest-public)
      (delete-directory/files dest-public))
    (copy-directory/files src-public dest-public)))

(define (delete-the-generated-entry p)
  (when (file-exists? p)
    (delete-file p)))
