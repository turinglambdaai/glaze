#lang racket/base

;; App packaging helpers used by `raco glaze build`. Wraps `raco exe` and
;; `raco distribute` so a Glaze project becomes a runnable directory (Windows)
;; or application bundle (macOS) with its frontend assets bundled.
;;
;; The frontend (public/) is declared via define-runtime-path in the generated
;; entry module, so raco distribute copies it next to the executable; at
;; runtime the app resolves the directory without depending on the working
;; directory.

(require racket/file
         racket/path
         racket/port
         racket/system
         "assets.rkt")

(provide build-app
         default-entry-template)

;; Build a Glaze project into a distributable.
;;
;;   #:entry    — the project's main.rkt path (default "main.rkt")
;;   #:name     — app name (default: entry's directory name)
;;   #:icon     — optional .ico (Windows) / .icns (macOS)
;;   #:out-dir  — output directory for the distribution (default "dist")
;;   #:embed-dlls? — Windows only: embed DLLs into a single .exe (default #f)
;;
;; Returns the path to the produced distribution directory.
(define (build-app #:entry [entry "main.rkt"]
                   #:name [name #f]
                   #:icon [icon #f]
                   #:out-dir [out-dir "dist"]
                   #:embed-dlls? [embed-dlls? #f]
                   #:installer? [installer? #f])
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
    (append (list "exe")
            (list "--gui")
            (if (and (eq? os 'windows) embed-dlls?)
                (list "--embed-dlls")
                '())
            (if icon-path
                (case os
                  [(windows) (list "--ico" (path->string icon-path))]
                  [(macosx) (list "--icns" (path->string icon-path))]
                  [else '()])
                '())
            (list "-o" (path->string out-exe-path) (path->string gen-entry))))

  (unless (apply system* (find-racket-bin) exe-args)
    (delete-the-generated-entry gen-entry)
    (error 'build-app "raco exe failed"))

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

  ;; Bundle the project's public/ next to the distribution so the packaged
  ;; app can serve its frontend. On macOS the assets go inside the .app bundle
  ;; Resources; elsewhere they sit beside the executable. The generated entry
  ;; sets current-directory to the executable's dir at runtime so the user's
  ;; relative #:public-dir "public" resolves to this copy.
  (copy-public-into-dist project-dir out-dir-path app-name os)

  ;; macOS post-processing: customize the bundle's Info.plist if produced.
  (when (eq? os 'macosx)
    (post-process-macos-bundle out-dir-path app-name icon-path))

  ;; Optional installer step. Each platform helper probes for the required
  ;; external tooling and warns (without failing the build) when it's absent;
  ;; the CI matrix installs them.
  (when installer?
    (make-installer os out-dir-path app-name))

  (path->complete-path (build-path out-dir-path)))

;; ---- Installer helpers ----
;; Each tries the best-available native installer tool and degrades to a plain
;; archive (.zip / .tar.gz) when the tool is missing, printing a warning so the
;; caller knows an installer wasn't produced.
(define (make-installer os out-dir app-name)
  (case os
    [(windows) (make-windows-installer out-dir app-name)]
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
(define (make-windows-installer out-dir app-name)
  (define dist (path->complete-path out-dir))
  (cond
    [(find-tool "wix.exe" "wix")
     (define msi-path (build-path dist (string-append app-name ".msi")))
     ;; WiX v4: `wix build -o out.msi <wxs>`; we generate a minimal wxs.
     (define wxs-path (build-path dist (string-append app-name ".wxs")))
     (call-with-output-file wxs-path
                            (lambda (out) (display (windows-wxs app-name dist) out))
                            #:exists 'replace)
     (unless (run (find-executable-path "wix.exe" #f)
                  "build"
                  "-o"
                  (path->string msi-path)
                  (path->string wxs-path))
       (fprintf (current-error-port) "[glaze] WiX build failed; see output above.\n"))]
    [(find-tool "makensis")
     (define nsis-path (build-path dist (string-append app-name ".nsi")))
     (call-with-output-file nsis-path
                            (lambda (out) (display (windows-nsis app-name dist) out))
                            #:exists 'replace)
     (unless (run (find-executable-path "makensis" #f) (path->string nsis-path))
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
  (cond
    [(find-tool "create-dmg")
     (run (find-executable-path "create-dmg" #f)
          "--volname"
          app-name
          (path->string (build-path dist (string-append app-name ".dmg")))
          (path->string bundle))]
    [(find-tool "hdiutil")
     (define dmg-path (build-path dist (string-append app-name ".dmg")))
     (run (find-executable-path "hdiutil" #f)
          "create"
          "-volname"
          app-name
          "-srcfolder"
          (path->string bundle)
          "-ov"
          "-format"
          "UDZO"
          (path->string dmg-path))]
    [else
     (display "[glaze] No macOS dmg toolchain found (create-dmg / hdiutil); " (current-error-port))
     (displayln "producing a .zip instead." (current-error-port))
     (archive-directory dist app-name "zip")]))

;; Linux: prefer appimagetool / linuxdeploy; else tar.gz.
(define (make-linux-installer out-dir app-name)
  (define dist (path->complete-path out-dir))
  (cond
    [(find-tool "appimagetool")
     (define appdir (build-path dist "AppDir"))
     (run (find-executable-path "appimagetool" #f)
          (path->string appdir)
          (path->string (build-path dist (string-append app-name ".AppImage"))))]
    [(find-tool "linuxdeploy")
     (putenv "OUTPUT" (path->string (build-path dist (string-append app-name ".AppImage"))))
     (run (find-executable-path "linuxdeploy" #f)
          "--appdir"
          (path->string (build-path dist "AppDir"))
          "--output"
          "appimage")]
    [else
     (display "[glaze] No Linux AppImage toolchain found (appimagetool / linuxdeploy); "
              (current-error-port))
     (displayln "producing a .tar.gz instead." (current-error-port))
     (archive-directory dist app-name "tar.gz")]))

;; Minimal WiX v4 source referencing the dist directory contents.
(define (windows-wxs app-name dist-dir)
  (format #<<WXEOF
<?xml version='1.0' encoding='windows-1252'?>
<Wix xmlns='http://wixtoolset.org/schemas/v4/wxs'>
  <Package Name='~a' Manufacturer='glaze' Version='0.2.0'>
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
;; host `tar` if present (handles both formats), else warns.
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
        (run (find-executable-path "powershell.exe" #f)
             "-NoProfile"
             "-Command"
             (format "Compress-Archive -Path '~a\\*' -DestinationPath '~a' -Force"
                     (path->string dist-abs)
                     (path->string archive-path)))]
       [(find-executable-path "zip" #f)
        (parameterize ([current-directory parent])
          (run (find-executable-path "zip" #f) "-r" (path->string archive-path) base))]
       [else (displayln "[glaze] No zip tool found; skipping archive." (current-error-port))])]
    ;; .tar.gz via tar -czf.
    [(and (equal? fmt "tar.gz") (find-executable-path "tar" #f))
     (run (find-executable-path "tar" #f)
          "-czf"
          (path->string archive-path)
          "-C"
          (path->string parent)
          base)]
    [else (displayln "[glaze] No archive tool found; skipping." (current-error-port))]))

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
   ";; Prefer the directory holding the packaged executable; fall back to the\n"
   ";; launcher's CWD when that directory has no bundled public/.\n"
   "(let* ([exe (find-system-path 'run-file)]\n"
   "       [dir (and (path? exe) (path-only exe))])\n"
   "  (when (and dir\n"
   "             (directory-exists? dir)\n"
   "             (or (directory-exists? (build-path dir \"public\"))\n"
   "                 (not (directory-exists? (build-path (current-directory) \"public\")))))\n"
   "    (current-directory dir)))\n"
   (format "(require \"~a\")\n" entry-filename)))

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
    ;; copy-directory/files creates the dest itself but fails if it already
    ;; exists, so remove a stale copy first (rebuilds).
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
;; and (optionally) LSUIElement so the tray app can be a pure menu-bar app.
;; No-op on non-macOS or if the bundle/plist is absent.
(define (post-process-macos-bundle out-dir app-name icon)
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
        (plist-set "CFBundleIdentifier" (string-append "io.glaze." app-name)))
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

(define (default-entry-template)
  entry-module-source)
