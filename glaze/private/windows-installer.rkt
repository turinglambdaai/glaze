#lang racket/base

;; Windows installer formats: prefer WiX v4 (MSI), then NSIS (setup exe),
;; else the archive fallback. The wizard/license templates live in
;; windows-installer-metadata; this owner only stages inputs and drives the
;; external toolchain.

(require racket/file
         racket/port
         "archive-fallback.rkt"
         "build-tools.rkt"
         (only-in "windows-installer-metadata.rkt"
                  windows-wxs
                  windows-nsis
                  text->rtf
                  project-license-text
                  default-license-notice))

(provide make-windows-installer
         ensure-wix-extensions!)

;; Windows: prefer WiX v4 (`wix`), then NSIS (`makensis`); else zip the dist.
(define (make-windows-installer out-dir
                                app-name
                                version
                                publisher
                                identifier
                                #:project-dir [project-dir #f]
                                #:license-rtf [license-rtf #f]
                                #:banner-bmp [banner-bmp #f]
                                #:dialog-bmp [dialog-bmp #f])
  (define dist (path->complete-path out-dir))
  (cond
    [(find-tool "wix.exe" "wix")
     (define msi-path (build-path dist (string-append app-name ".msi")))
     (when (file-exists? msi-path)
       (delete-file msi-path))
     ;; WiX v4: `wix build -o out.msi <wxs>`; keep compiler side-products
     ;; outside the application directory being harvested.
     (define wix-temp (make-temporary-file "glaze-installer-~a" 'directory))
     (define wxs-path (build-path wix-temp (string-append app-name ".wxs")))
     (define temp-msi (build-path wix-temp (string-append app-name ".msi")))
     ;; The wizard's license page always needs an RTF: the configured one is
     ;; used verbatim, otherwise the repository license text renders into
     ;; RTF, and a project with neither gets a neutral notice.
     (define license-path
       (or license-rtf
           (let ([generated (build-path wix-temp "license.rtf")])
             (call-with-output-file generated
                                    #:exists 'truncate/replace
                                    (lambda (out)
                                      (display (text->rtf (or (project-license-text project-dir)
                                                              default-license-notice))
                                               out)))
             generated)))
     (define wix-arch
       (case (system-type 'arch)
         [(x86_64 amd64) "x64"]
         [(aarch64 arm64) "arm64"]
         [else "x86"]))
     (dynamic-wind (lambda ()
                     (call-with-output-file wxs-path
                                            (lambda (out)
                                              (display (windows-wxs app-name
                                                                    dist
                                                                    version
                                                                    publisher
                                                                    identifier
                                                                    #:license-rtf license-path
                                                                    #:banner-bmp banner-bmp
                                                                    #:dialog-bmp dialog-bmp)
                                                       out))
                                            #:exists 'replace))
                   (lambda ()
                     (define wix
                       (or (find-executable-path "wix.exe" #f) (find-executable-path "wix" #f)))
                     (ensure-wix-extensions! wix)
                     (if (run wix
                              "build"
                              "-arch"
                              wix-arch
                              "-ext"
                              "WixToolset.UI.wixext"
                              "-ext"
                              "WixToolset.Util.wixext"
                              "-o"
                              (path->string temp-msi)
                              (path->string wxs-path))
                         (begin
                           ;; The system temp directory and the project can be
                           ;; on different Windows volumes (for example C: and
                           ;; D: on GitHub runners), where rename cannot work.
                           (copy-file temp-msi msi-path #t)
                           msi-path)
                         (error 'build-app "WiX build failed; see output above")))
                   (lambda ()
                     (when (directory-exists? wix-temp)
                       (delete-directory/files wix-temp))))]
    [(find-tool "makensis")
     (define nsis-path (make-temporary-file "glaze-installer-~a.nsi"))
     (define setup-exe (build-path dist (string-append app-name "-setup.exe")))
     (when (file-exists? setup-exe)
       (delete-file setup-exe))
     (dynamic-wind (lambda ()
                     (call-with-output-file
                      nsis-path
                      (lambda (out)
                        (display (windows-nsis app-name dist version publisher identifier) out))
                      #:exists 'replace))
                   (lambda ()
                     (if (run (find-executable-path "makensis" #f) (path->string nsis-path))
                         setup-exe
                         (error 'build-app "NSIS build failed; see output above")))
                   (lambda ()
                     (when (file-exists? nsis-path)
                       (delete-file nsis-path))))]
    [else
     (display "[glaze] No Windows installer toolchain found (wix / makensis); " (current-error-port))
     (displayln "producing a .zip instead. Install WiX Toolset or NSIS for a real installer."
                (current-error-port))
     (archive-directory dist app-name "zip")]))

;; The wix CLI resolves -ext references only from its local extension cache,
;; so the matching UI and Util extension versions are installed on demand.
(define (ensure-wix-extensions! wix)
  (define version-output (with-output-to-string (lambda () (run wix "--version"))))
  (define version-match (regexp-match #px"^[0-9]+\\.[0-9]+\\.[0-9]+" version-output))
  (define version (and version-match (car version-match)))
  (for ([extension (in-list '("WixToolset.UI.wixext" "WixToolset.Util.wixext"))])
    (run wix
         "extension"
         "add"
         "-g"
         (if version
             (string-append extension "/" version)
             extension))))
