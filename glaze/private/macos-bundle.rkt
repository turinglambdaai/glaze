#lang racket/base

;; macOS staging and installer formats: assemble the canonical .app bundle
;; from `raco distribute` output, patch its Info.plist, and produce the dmg
;; (branded drag-to-install layout, create-dmg, plain hdiutil, or the archive
;; fallback).

(require racket/file
         racket/list
         racket/system
         racket/path
         racket/port
         racket/string
         "archive-fallback.rkt"
         "build-tools.rkt"
         (only-in "macos-bundle-metadata.rkt" macos-info-plist)
         (only-in "windows-installer-metadata.rkt" dmg-style-applescript))

(provide assemble-macos-bundle
         post-process-macos-bundle
         make-macos-installer
         create-branded-dmg!)

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
   (bitwise-ior (file-or-directory-permissions (build-path macos-dir app-name) 'bits) user-write-bit))
  (when (directory-exists? dist-lib)
    (rename-file-or-directory dist-lib (build-path contents "lib")))
  (delete-directory/files dist-bin)
  (call-with-output-file (build-path contents "PkgInfo")
                         (lambda (o) (display "APPL????" o))
                         #:exists 'replace)
  (call-with-output-file (build-path contents "Info.plist")
                         (lambda (o) (display (macos-info-plist app-name version url-schemes) o))
                         #:exists 'replace))

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

;; macOS: branded drag-to-install layout when a background is declared,
;; else prefer create-dmg, then plain hdiutil; else zip the .app.
(define (make-macos-installer out-dir app-name [dmg-background #f])
  (define dist (path->complete-path out-dir))
  (define bundle (build-path dist (string-append app-name ".app")))
  (define dmg-path (build-path dist (string-append app-name ".dmg")))
  (cond
    [(and dmg-background (find-executable-path "hdiutil" #f))
     (create-branded-dmg! (find-executable-path "hdiutil" #f)
                          dmg-background
                          bundle
                          dmg-path
                          app-name)]
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

;; Commercial drag-to-install image: stage the volume contents (bundle,
;; /Applications link, hidden background asset), attach a read/write image
;; through /Volumes (Finder only addresses volumes there), let Finder size
;; the window and place both icons, then convert to the compressed output.
(define (create-branded-dmg! hdiutil background bundle dmg-path app-name)
  (define staging (make-temporary-file "glaze-dmg-~a" 'directory))
  (define staging-app (build-path staging (string-append app-name ".app")))
  (define rw-image (build-path staging "dmg-rw.dmg"))
  (define script-path (build-path staging "dmg-style.applescript"))
  (dynamic-wind
   (lambda () #f)
   (lambda ()
     (copy-directory/files bundle staging-app)
     (make-file-or-directory-link "/Applications" (build-path staging "Applications"))
     (make-directory* (build-path staging ".background"))
     (copy-file background (build-path staging ".background" "background.png"))
     (define attach-output
       (with-output-to-string
        (lambda ()
          (unless (run hdiutil
                       "create"
                       "-fs"
                       "HFS+"
                       "-volname"
                       app-name
                       "-srcfolder"
                       (path->string staging)
                       "-format"
                       "UDRW"
                       "-ov"
                       (path->string rw-image))
            (error 'build-app "hdiutil create failed"))
          (unless (run hdiutil "attach" (path->string rw-image) "-noautoopen" "-readwrite")
            (error 'build-app "hdiutil attach failed")))))
     (define mount-path
       (let* ([line (last (string-split (string-trim attach-output) "\n"))]
              [fields (string-split line "\t")])
         (string-trim (last fields))))
     (define disk-name (last (string-split mount-path "/")))
     (call-with-output-file script-path
                            #:exists 'truncate/replace
                            (lambda (out) (display (dmg-style-applescript disk-name app-name) out)))
     (define (detach!)
       (with-handlers ([exn:fail? void])
         (unless (run hdiutil "detach" mount-path)
           (run hdiutil "detach" "-force" mount-path))))
     (with-handlers ([exn:fail? (lambda (e)
                                  (detach!)
                                  (raise e))])
       (unless (run (find-executable-path "osascript" #f) (path->string script-path))
         (error 'build-app "DMG layout script failed; see output above"))
       (when (find-executable-path "sync" #f)
         (run (find-executable-path "sync" #f)))
       (detach!))
     (when (file-exists? dmg-path)
       (delete-file dmg-path))
     (unless (run hdiutil
                  "convert"
                  (path->string rw-image)
                  "-format"
                  "UDZO"
                  "-ov"
                  "-o"
                  (path->string dmg-path))
       (error 'build-app "hdiutil convert failed"))
     dmg-path)
   (lambda ()
     (when (directory-exists? staging)
       (delete-directory/files staging)))))
