#lang racket/base

;; App packaging helpers used by `raco glaze build`. Wraps `raco exe` and
;; `raco distribute` so a Glaze project becomes a runnable directory (Windows)
;; or application bundle (macOS) with its frontend assets bundled.
;;
;; The user's entry module is compiled directly so normal Racket
;; `(module+ main ...)` semantics are preserved. Frontend assets are copied
;; into the distribution and resolved at runtime by glaze/assets.

(require racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system
         "assets.rkt")

(provide build-app
         default-entry-template)

;; Build a Glaze project into a distributable.
;;
;;   #:entry    — the project's main.rkt path (default "main.rkt")
;;   #:name     — app name (default: entry's directory name)
;;   #:version  — app version string; goes into the macOS Info.plist
;;                (CFBundleShortVersionString / CFBundleVersion) and the
;;                Windows MSI ProductVersion (default "0.0.0")
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
;;
;; Returns the path to the produced distribution directory.
(define (build-app #:entry [entry "main.rkt"]
                   #:name [name #f]
                   #:version [version #f]
                   #:icon [icon #f]
                   #:out-dir [out-dir "dist"]
                   #:embed-dlls? [embed-dlls? #f]
                   #:installer? [installer? #f]
                   #:sign [sign #f]
                   #:entitlements [entitlements #f]
                   #:no-hardened-runtime? [no-hardened-runtime? #f]
                   #:timestamp-url [timestamp-url #f]
                   #:notarize-profile [notarize-profile #f]
                   #:url-schemes [url-schemes '()])
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

  ;; Compile the user's actual entry module. Compiling a wrapper that merely
  ;; required main.rkt skipped the user's `(module+ main ...)` submodule and
  ;; could produce an executable that immediately exited with status 0.
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
            (if (eq? os 'windows) (list "--gui") '())
            (if (and (eq? os 'windows) embed-dlls?)
                (list "--embed-dlls")
                '())
            (if icon-path
                (case os
                  [(windows) (list "--ico" (path->string icon-path))]
                  [(macosx) (list "--icns" (path->string icon-path))]
                  [else '()])
                '())
            (list "-o" (path->string out-exe-path) (path->string entry-abs))))

  (unless (apply system* (find-racket-bin) exe-args)
    (error 'build-app "raco exe failed"))

  ;; raco exe emits a read-only launcher; `raco distribute` needs to rewrite
  ;; the copy it makes (Mach-O/ELF segment patching) and fails with EACCES
  ;; on some Racket versions otherwise.
  (file-or-directory-permissions
   out-exe-path
   (bitwise-ior (file-or-directory-permissions out-exe-path 'bits) user-write-bit))

  ;; Distribute. On Windows --embed-dlls already yields a near-standalone exe,
  ;; but we still run distribute to collect any remaining runtime files and to
  ;; produce a consistent layout across platforms.
  (define dist-args (list "distribute" (path->string out-dir-path) (path->string out-exe-path)))
  (unless (apply system* (find-racket-bin) dist-args)
    (error 'build-app "raco distribute failed"))

  ;; Clean up the standalone exe copy (distribute has its own copy inside
  ;; out-dir).
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
  ;; Resources; elsewhere they sit beside the executable. glaze/assets
  ;; resolves a relative #:public-dir against these packaged locations without
  ;; changing the process current directory.
  (copy-public-into-dist project-dir out-dir-path app-name os)

  ;; macOS post-processing: customize the bundle's Info.plist if produced.
  (when (eq? os 'macosx)
    (post-process-macos-bundle out-dir-path app-name icon-path version))

  ;; Sign before installers: the macOS dmg wraps the signed .app and the
  ;; Windows msi embeds the signed exe. Signing failures abort the build
  ;; (shipping an unsigned "signed" dist is worse than a failed build);
  ;; a missing TOOL degrades with a warning, matching the installer steps.
  (when sign
    (sign-dist os out-dir-path app-name
               sign entitlements
               (not no-hardened-runtime?)
               timestamp-url))

  ;; Optional installer step. Each platform helper probes for the required
  ;; external tooling and warns (without failing the build) when it's absent;
  ;; the CI matrix installs them. Returns the produced artifact path (or #f).
  (define installer-artifact
    (if installer?
        (make-installer os out-dir-path app-name (or version "0.0.0"))
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
;; path, or #f when nothing could be produced.
(define (make-installer os out-dir app-name [version "0.0.0"])
  (case os
    [(windows) (make-windows-installer out-dir app-name version)]
    [(macosx) (make-macos-installer out-dir app-name)]
    [else (make-linux-installer out-dir app-name)]))

;; Returns the first argv[0]-resolvable command among names, or #f.
(define (find-tool . names)
  (for/first ([n (in-list names)]
              #:when (find-executable-path n #f))
    n))

(define (run . args)
  (apply system* args))

;; Windows: prefer WiX v4 (`wix`), then NSIS (`makensis`); else zip the dist.
(define (make-windows-installer out-dir app-name [version "0.0.0"])
  (define dist (path->complete-path out-dir))
  (cond
    [(find-tool "wix.exe" "wix")
     (define msi-path (build-path dist (string-append app-name ".msi")))
     ;; WiX v4: `wix build -o out.msi <wxs>`; we generate a minimal wxs.
     (define wxs-path (build-path dist (string-append app-name ".wxs")))
     (call-with-output-file wxs-path
                            (lambda (out) (display (windows-wxs app-name dist version) out))
                            #:exists 'replace)
     (if (run (find-executable-path "wix.exe" #f)
              "build"
              "-o"
              (path->string msi-path)
              (path->string wxs-path))
         msi-path
         (fprintf (current-error-port) "[glaze] WiX build failed; see output above.\n"))]
    [(find-tool "makensis")
     (define nsis-path (build-path dist (string-append app-name ".nsi")))
     (call-with-output-file nsis-path
                            (lambda (out) (display (windows-nsis app-name dist) out))
                            #:exists 'replace)
     (define setup-exe (build-path dist (string-append app-name "-setup.exe")))
     (if (run (find-executable-path "makensis" #f) (path->string nsis-path))
         setup-exe
         (fprintf (current-error-port) "[glaze] NSIS build failed; see output above.\n"))]
    [else
     (display "[glaze] No Windows installer toolchain found (wix / makensis); " (current-error-port))
     (displayln "producing a .zip instead. Install WiX Toolset or NSIS for a real installer."
                (current-error-port))
     (archive-directory dist app-name "zip")]))

;; macOS: prefer create-dmg, then hdiutil; else zip the .app.
(define (make-macos-installer out-dir app-name)
  (define dist (path->complete-path out-dir))
  (define bundle (build-path dist (string-append app-name ".app")))
  (define dmg-path (build-path dist (string-append app-name ".dmg")))
  (cond
    [(find-tool "create-dmg")
     (and (run (find-executable-path "create-dmg" #f)
               "--volname"
               app-name
               (path->string dmg-path)
               (path->string bundle))
          dmg-path)]
    [(find-tool "hdiutil")
     (and (run (find-executable-path "hdiutil" #f)
               "create"
               "-volname"
               app-name
               "-srcfolder"
               (path->string bundle)
               "-ov"
               "-format"
               "UDZO"
               (path->string dmg-path))
          dmg-path)]
    [else
     (display "[glaze] No macOS dmg toolchain found (create-dmg / hdiutil); " (current-error-port))
     (displayln "producing a .zip instead." (current-error-port))
     (archive-directory dist app-name "zip")]))

;; Linux: prefer appimagetool / linuxdeploy; else tar.gz.
(define (make-linux-installer out-dir app-name)
  (define dist (path->complete-path out-dir))
  (define appimage-path (build-path dist (string-append app-name ".AppImage")))
  (cond
    [(find-tool "appimagetool")
     (define appdir (build-path dist "AppDir"))
     (and (run (find-executable-path "appimagetool" #f)
               (path->string appdir)
               (path->string appimage-path))
          appimage-path)]
    [(find-tool "linuxdeploy")
     (putenv "OUTPUT" (path->string appimage-path))
     (and (run (find-executable-path "linuxdeploy" #f)
               "--appdir"
               (path->string (build-path dist "AppDir"))
               "--output"
               "appimage")
          appimage-path)]
    [else
     (display "[glaze] No Linux AppImage toolchain found (appimagetool / linuxdeploy); "
              (current-error-port))
     (displayln "producing a .tar.gz instead." (current-error-port))
     (archive-directory dist app-name "tar.gz")]))

;; Minimal WiX v4 source referencing the dist directory contents.
(define (windows-wxs app-name dist-dir [version "0.0.0"])
  (format #<<WXEOF
<?xml version='1.0' encoding='windows-1252'?>
<Wix xmlns='http://wixtoolset.org/schemas/v4/wxs'>
  <Package Name='~a' Manufacturer='glaze' Version='~a'>
    <MajorUpgrade DowngradeErrorMessage='A newer version is already installed.' />
    <Directory Id='TARGETDIR' Name='SourceDir'>
      <Directory Id='ProgramFilesFolder'>
        <Directory Id='INSTALLDIR' Name='~a'>
          <Component Id='App' Guid='*'>
            <Files Include='~a\\**' />
          </Component>
        </Directory>
      </Directory>
    </Directory>
    <Feature Id='Complete' Title='~a' Level='1'>
      <ComponentRef Id='App' />
    </Feature>
  </Package>
</Wix>
WXEOF
          app-name
          version
          app-name
          (path->string dist-dir)
          app-name))

;; Minimal NSIS script.
(define (windows-nsis app-name dist-dir)
  (format #<<NSI
Name "~a"
OutFile "~a\\~a-setup.exe"
InstallDir "$PROGRAMFILES\\~a"
Page directory
Page instfiles
Section ""
  SetOutPath "$INSTDIR"
  File /r "~a\\*.*"
  CreateShortcut "$DESKTOP\\~a.lnk" "$INSTDIR\\~a.exe"
SectionEnd
NSI
          app-name
          (path->string dist-dir)
          app-name
          app-name
          (path->string dist-dir)
          app-name
          app-name))

;; Produce a zip or tar.gz of dist contents as a portable fallback. Uses the
;; host `tar` if present (handles both formats), else warns. Returns the
;; archive path, or #f when no tool was available.
(define (archive-directory dist-dir app-name fmt)
  (define dist-abs (path->complete-path dist-dir))
  (define parent (or (path-only dist-abs) dist-abs))
  (define base (path->string (file-name-from-path dist-abs)))
  (define archive-path (build-path parent (string-append base "." fmt)))
  (cond
    ;; .zip via PowerShell on Windows, else the `zip` CLI.
    [(equal? fmt "zip")
     (cond
       [(and (eq? (system-type 'os) 'windows) (find-executable-path "powershell.exe" #f))
        (and (run (find-executable-path "powershell.exe" #f)
                  "-NoProfile"
                  "-Command"
                  (format "Compress-Archive -Path '~a\\*' -DestinationPath '~a' -Force"
                          (path->string dist-abs)
                          (path->string archive-path)))
             archive-path)]
       [(find-executable-path "zip" #f)
        (and (parameterize ([current-directory parent])
               (run (find-executable-path "zip" #f) "-r" (path->string archive-path) base))
             archive-path)]
       [else (displayln "[glaze] No zip tool found; skipping archive." (current-error-port)) #f])]
    ;; .tar.gz via tar -czf.
    [(and (equal? fmt "tar.gz") (find-executable-path "tar" #f))
     (and (run (find-executable-path "tar" #f)
               "-czf"
               (path->string archive-path)
               "-C"
               (path->string parent)
               base)
          archive-path)]
    [else
     (displayln "[glaze] No archive tool found; skipping." (current-error-port))
     #f]))

;; The generated entry module: requires glaze and the user's main (whose
;; server startup runs). At runtime it sets the working directory to the
;; directory of the packaged executable, so a relative #:public-dir "public"
;; in the user's main.rkt resolves to the public/ we copy next to the
;; distribution (see copy-public-into-dist in build-app). It tries the
;; executable's own directory first, then falls back to the original CWD if
;; that directory does not contain a public/ (covering launchers that report
;; a wrapper path).
(define (entry-module-source user-entry)
  (define entry-filename
    (let ([p (if (complete-path? user-entry)
                 user-entry
                 (path->complete-path user-entry))])
      (path->string (file-name-from-path p))))
  (string-append
   "#lang racket/base\n"
   "(require racket/path)\n"
   "(require glaze)\n"
   ";; Prefer the directory holding the packaged executable; inside a macOS\n"
   ";; .app also try ../Resources/public; fall back to the launcher's CWD.\n"
   "(let* ([exe (find-system-path 'run-file)]\n"
   "       [dir (and (path? exe) (path-only exe))]\n"
   "       [candidates (list dir\n"
   "                         (and dir (build-path dir \"..\" \"Resources\")))]\n"
   "       [pick (for/or ([c (in-list candidates)])\n"
   "               (and c (directory-exists? (build-path c \"public\")) c))])\n"
   "  (when (and pick (not (directory-exists? (build-path (current-directory) \"public\"))))\n"
   "    (current-directory pick)))\n"
   (format "(require \"~a\")\n" entry-filename)))

;; Assemble a canonical macOS .app bundle from whatever `raco distribute`
;; produced. Current versions lay out <dist>/bin/<name> + <dist>/lib/; older
;; ones differ — the launcher's library rpath (@executable_path/../lib) has
;; the same depth in Contents/MacOS as in bin/, so moving both preserves
;; resolution either way. Also writes the base Info.plist (name, bundle id,
;; executable, versions) and PkgInfo; the icon and remaining plist keys are
;; patched afterwards by post-process-macos-bundle.
(define (assemble-macos-bundle out-dir app-name version [url-schemes '()])
  (define dist (path->complete-path out-dir))
  (define dist-bin (build-path dist "bin"))
  (define dist-lib (build-path dist "lib"))
  (define bundle (build-path dist (string-append app-name ".app")))
  (define contents (build-path bundle "Contents"))
  (define macos-dir (build-path contents "MacOS"))
  (define exe-src (build-path dist-bin app-name))
  (unless (file-exists? exe-src)
    (error 'build-app "macOS bundle assembly failed: no executable at ~a" exe-src))
  (make-directory* macos-dir)
  (rename-file-or-directory exe-src (build-path macos-dir app-name))
  (file-or-directory-permissions
   (build-path macos-dir app-name)
   (bitwise-ior (file-or-directory-permissions (build-path macos-dir app-name) 'bits)
                user-write-bit))
  (when (directory-exists? dist-lib)
    (rename-file-or-directory dist-lib (build-path contents "lib")))
  (delete-directory/files dist-bin)
  (call-with-output-file (build-path contents "PkgInfo")
                         (lambda (o) (display "APPL????" o))
                         #:exists 'replace)
  (call-with-output-file (build-path contents "Info.plist")
                         (lambda (o) (display (macos-info-plist app-name version url-schemes) o))
                         #:exists 'replace))

(define (macos-info-plist app-name version [url-schemes '()])
  (format #<<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>~a</string>
  <key>CFBundleDisplayName</key><string>~a</string>
  <key>CFBundleIdentifier</key><string>io.glaze.~a</string>
  <key>CFBundleExecutable</key><string>~a</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>~a</string>
  <key>CFBundleVersion</key><string>~a</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.13</string>~a
</dict>
</plist>
PLIST
          app-name app-name app-name app-name version version
          (if (null? url-schemes)
              ""
              (string-append
               "\n  <key>CFBundleURLTypes</key>\n  <array>\n    <dict>\n"
               "      <key>CFBundleURLName</key><string>io.glaze."
               app-name
               "</string>\n"
               "      <key>CFBundleURLSchemes</key>\n      <array>\n"
               (string-join
                (for/list ([sc (in-list url-schemes)])
                  (format "        <string>~a</string>\n" sc))
                "")
               "      </array>\n    </dict>\n  </array>"))))
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

;; Locate the raco executable for subprocess calls (exe + distribute live under
;; raco, not racket).
(define (find-racket-bin)
  (or (find-executable-path (if (eq? (system-type 'os) 'windows) "raco.exe" "raco") #f)
      (error 'build-app "could not locate the raco executable")))

;; On macOS, after raco distribute, patch Info.plist for app name, bundle id,
;; version, and (optionally) LSUIElement so the tray app can be a pure
;; menu-bar app. No-op on non-macOS or if the bundle/plist is absent.
(define (post-process-macos-bundle out-dir app-name icon [version #f])
  (define bundle (build-path out-dir (string-append app-name ".app")))
  (define plist (build-path bundle "Contents" "Info.plist"))
  (when (file-exists? plist)
    (define pb (find-executable-path "PlistBuddy" #f))
    (when pb
      (define (plist-set key val)
        (system* pb "-c" (format "Set :~a ~a" key val) plist))
      (with-handlers ([exn:fail? void])
        (plist-set "CFBundleName" app-name)
        (plist-set "CFBundleDisplayName" app-name)
        (plist-set "CFBundleIdentifier" (string-append "io.glaze." app-name))
        (when version
          (plist-set "CFBundleShortVersionString" version)
          (plist-set "CFBundleVersion" version)))
      (when (and icon (file-exists? icon))
        ;; Copy the icon into Resources and reference it.
        (define icns-name (path->string (file-name-from-path icon)))
        (define res-dir (build-path bundle "Contents" "Resources"))
        (make-directory* res-dir)
        (call-with-output-file (build-path res-dir icns-name)
                               (lambda (out)
                                 (call-with-input-file icon (lambda (in) (copy-port in out))))
                               #:exists 'replace)
        (with-handlers ([exn:fail? void])
          (system* pb "-c" (format "Set :CFBundleIconFile ~a" icns-name) plist))))))

;; ---- Code signing & notarization ----

(define default-timestamp-url "http://timestamp.digicert.com")

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
  (define hardened?
    (and hardened-runtime? (not (equal? identity "-"))))
  ;; codesign rewrites the main executable — make sure it is writable.
  (define main-exe
    (build-path bundle "Contents" "MacOS"
                (path->string (file-name-from-path bundle))))
  (when (file-exists? main-exe)
    (file-or-directory-permissions
     main-exe
     (bitwise-ior (file-or-directory-permissions main-exe 'bits) user-write-bit)))
  (define common-args
    (append (list "--force" "--sign" identity)
            (if hardened? (list "--options" "runtime") '())))
  ;; 1. nested libraries: frameworks ship as versioned dylibs that codesign
  ;;    may not recognize as bundles, so sign each file; non-code files
  ;;    fail harmlessly and are skipped.
  (define lib-dir (build-path bundle "Contents" "lib"))
  (when (directory-exists? lib-dir)
    (for ([p (in-directory lib-dir)]
          #:when (file-exists? p))
      (apply system*/exit-code codesign
             (append common-args (list (path->string p))))))
  ;; 2. the bundle itself: signs the main executable and seals resources.
  (define args
    (append common-args
            (if entitlements
                (list "--entitlements" (path->string (path->complete-path entitlements)))
                '())
            (list (path->string bundle))))
  (unless (zero? (apply system*/exit-code codesign args))
    (error 'build-app "codesign failed for ~a (identity ~a)" bundle identity))
  (unless (zero? (system*/exit-code codesign "--verify" "--strict"
                                    (path->string bundle)))
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
    (define cert-flag
      ;; A 40-hex string is a SHA-1 thumbprint; anything else is a subject name.
      (if (regexp-match? #px"^[0-9a-fA-F]{40}$" cert-spec) "/sha1" "/n"))
    (define args
      (append (list "sign" "/fd" "SHA256" cert-flag cert-spec)
              (if timestamp-url (list "/tr" timestamp-url "/td" "SHA256") '())
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
    (displayln "[glaze] notarization only applies to macOS builds; ignoring."
               (current-error-port))
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
                                                "-qr" (path->string zip)
                                                (string-append app-name ".app")))
                (error 'build-app "could not zip the .app for notarization")))
            zip)))
    (unless (zero? (system*/exit-code xcrun "notarytool" "submit"
                                        (path->string artifact)
                                        "--keychain-profile" keychain-profile
                                        "--wait"))
      (error 'build-app "notarization failed for ~a (profile ~a)" artifact keychain-profile))
    (define staple-target
      (if (file-exists? dmg) dmg bundle))
    (system*/exit-code xcrun "stapler" "staple" (path->string staple-target))
    (fprintf (current-error-port) "[glaze] notarized: ~a\n" staple-target)
    #t))

(define (default-entry-template)
  entry-module-source)
