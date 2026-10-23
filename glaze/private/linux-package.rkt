#lang racket/base

;; Linux package formats: AppImage (appimagetool / linuxdeploy), deb
;; (dpkg-deb), and rpm (rpmbuild), all sharing one /usr-style staging tree,
;; with a tar.gz fallback when no toolchain exists. Each format degrades
;; independently; one failing tool never blocks the others. Package metadata
;; text lives in linux-package-metadata.

(require racket/file
         racket/list
         racket/path
         racket/string
         "archive-fallback.rkt"
         "build-tools.rkt"
         (only-in "linux-package-metadata.rkt"
                  deb-arch-name
                  deb-control
                  desktop-entry
                  icon-png-bytes
                  rpm-spec
                  sanitize-package-name))

(provide make-linux-installer
         linux-staging-tree)

;; POSIX permission bits only exist on Unix hosts; Windows raises for
;; anything beyond the write bits, and the staging tree is exercised
;; cross-platform as pure file work.
(define (set-executable-mode! path)
  (unless (eq? (system-type 'os) 'windows)
    (file-or-directory-permissions path #o755)))

(define (make-linux-installer out-dir app-name version publisher identifier)
  (define dist (path->complete-path out-dir))
  (define artifacts
    (filter values
            (list (linux-appimage! dist app-name)
                  (linux-deb! dist app-name version publisher identifier)
                  (linux-rpm! dist app-name version publisher identifier))))
  (cond
    [(pair? artifacts)
     (for ([artifact (in-list artifacts)])
       (fprintf (current-error-port) "[glaze] Linux package: ~a\n" artifact))
     (first artifacts)]
    [else
     (display "[glaze] No Linux packaging toolchain found "
              "(appimagetool / dpkg-deb / rpmbuild); "
              (current-error-port))
     (displayln "producing a .tar.gz instead." (current-error-port))
     (archive-directory dist app-name "tar.gz")]))

;; ---- staging tree shared by deb / rpm / AppImage ----

;; Build a /usr-style tree outside dist: the whole runtime lands in
;; /usr/lib/<app>, a shell wrapper at /usr/bin/<app> keeps raco
;; distribute's relative bin/ + lib/ layout intact, and a desktop entry
;; plus hicolor icon integrate with the desktop environment.
(define (linux-staging-tree dist app-name)
  (define root (make-temporary-file "glaze-pkg-~a" 'directory))
  (define lib-dir (build-path root "usr" "lib" app-name))
  (make-directory* lib-dir)
  (define artifact-suffixes '(".AppImage" ".deb" ".rpm" ".msi" ".exe" ".zip" ".tar.gz"))
  (define (artifact? path)
    (define name (path->string (file-name-from-path path)))
    (or (string=? name "AppDir")
        (for/or ([suffix (in-list artifact-suffixes)])
          (string-suffix? name suffix))))
  (for ([entry (in-list (directory-list dist))])
    (unless (artifact? entry)
      (copy-directory/files (build-path dist entry) (build-path lib-dir entry))))
  (define exe (build-path lib-dir "bin" app-name))
  (and (file-exists? exe)
       (let ()
         (define bin-dir (build-path root "usr" "bin"))
         (make-directory* bin-dir)
         (define wrapper (build-path bin-dir app-name))
         (call-with-output-file
          wrapper
          (lambda (out) (fprintf out "#!/bin/sh\nexec /usr/lib/~a/bin/~a \"$@\"\n" app-name app-name))
          #:exists 'replace)
         (set-executable-mode! wrapper)
         (define apps-dir (build-path root "usr" "share" "applications"))
         (make-directory* apps-dir)
         (call-with-output-file
          (build-path apps-dir (string-append app-name ".desktop"))
          (lambda (out) (display (desktop-entry app-name (sanitize-package-name app-name)) out))
          #:exists 'replace)
         (define icon-dir (build-path root "usr" "share" "icons" "hicolor" "64x64" "apps"))
         (make-directory* icon-dir)
         (call-with-output-file (build-path icon-dir
                                            (string-append (sanitize-package-name app-name) ".png"))
                                (lambda (out) (write-bytes (icon-png-bytes) out))
                                #:exists 'replace)
         root)))

;; ---- format builders (each degrades to #f) ----

(define (linux-deb! dist app-name version publisher identifier)
  (with-handlers ([exn:fail? (lambda (e)
                               (fprintf (current-error-port)
                                        "[glaze] deb packaging unavailable: ~a\n"
                                        (exn-message e))
                               #f)])
    (define dpkg-deb (find-executable-path "dpkg-deb" #f))
    (and dpkg-deb
         (let ()
           (define root (linux-staging-tree dist app-name))
           (and root
                (dynamic-wind
                 (lambda () (void))
                 (lambda ()
                   (make-directory* (build-path root "DEBIAN"))
                   (call-with-output-file
                    (build-path root "DEBIAN" "control")
                    (lambda (out)
                      (display (deb-control app-name version publisher (deb-arch-name)) out))
                    #:exists 'replace)
                   (define deb-path (build-path dist (string-append app-name ".deb")))
                   (and (run dpkg-deb "--root-owner-group" "--build" root (path->string deb-path))
                        (file-exists? deb-path)
                        deb-path))
                 (lambda () (delete-tree-quietly! root))))))))

(define (linux-rpm! dist app-name version publisher identifier)
  (with-handlers ([exn:fail? (lambda (e)
                               (fprintf (current-error-port)
                                        "[glaze] rpm packaging unavailable: ~a\n"
                                        (exn-message e))
                               #f)])
    (define rpmbuild (find-executable-path "rpmbuild" #f))
    (and rpmbuild
         (let ()
           (define root (linux-staging-tree dist app-name))
           (and root
                (dynamic-wind
                 (lambda () (void))
                 (lambda ()
                   (define top (make-temporary-file "glaze-rpm-~a" 'directory))
                   (for ([sub (in-list '("BUILD" "RPMS" "SOURCES" "SPECS" "SRPMS"))])
                     (make-directory* (build-path top sub)))
                   (define spec-path (build-path top "SPECS" (string-append app-name ".spec")))
                   (call-with-output-file spec-path
                                          (lambda (out)
                                            (display (rpm-spec app-name version publisher root) out))
                                          #:exists 'replace)
                   (define ok?
                     (run rpmbuild
                          "-bb"
                          (path->string spec-path)
                          "--define"
                          (string-append "_topdir " (path->string top))))
                   (define rpm-path (build-path dist (string-append app-name ".rpm")))
                   (when ok?
                     (define candidate
                       (let loop ([dir (build-path top "RPMS")])
                         (append-map (lambda (entry)
                                       (define full (build-path dir entry))
                                       (cond
                                         [(directory-exists? full) (loop full)]
                                         [(string-suffix? (path->string entry) ".rpm") (list full)]
                                         [else '()]))
                                     (directory-list dir))))
                     (when (pair? candidate)
                       (copy-file (first candidate) rpm-path #t)))
                   (and (file-exists? rpm-path) rpm-path))
                 (lambda () (delete-tree-quietly! root))))))))

(define (linux-appimage! dist app-name)
  (with-handlers ([exn:fail? (lambda (e)
                               (fprintf (current-error-port)
                                        "[glaze] AppImage packaging unavailable: ~a\n"
                                        (exn-message e))
                               #f)])
    (define tool (find-tool "appimagetool" "linuxdeploy"))
    (and
     tool
     (let ()
       (define root (linux-staging-tree dist app-name))
       (and root
            (dynamic-wind
             (lambda () (void))
             (lambda ()
               ;; AppDir: the /usr tree plus the desktop entry, icon,
               ;; and AppRun at the root, which is what appimagetool
               ;; and desktop launchers expect.
               (define appdir (build-path dist "AppDir"))
               (when (directory-exists? appdir)
                 (delete-tree-quietly! appdir))
               (make-directory* appdir)
               (copy-directory/files (build-path root "usr") (build-path appdir "usr"))
               (call-with-output-file
                (build-path appdir (string-append app-name ".desktop"))
                (lambda (out) (display (desktop-entry app-name (sanitize-package-name app-name)) out))
                #:exists 'replace)
               (copy-file (build-path root
                                      "usr"
                                      "share"
                                      "icons"
                                      "hicolor"
                                      "64x64"
                                      "apps"
                                      (string-append (sanitize-package-name app-name) ".png"))
                          (build-path appdir (string-append (sanitize-package-name app-name) ".png"))
                          #t)
               (call-with-output-file
                (build-path appdir "AppRun")
                (lambda (out)
                  (fprintf out "#!/bin/sh\nexec /usr/lib/~a/bin/~a \"$@\"\n" app-name app-name))
                #:exists 'replace)
               (set-executable-mode! (build-path appdir "AppRun"))
               (define appimage-path (build-path dist (string-append app-name ".AppImage")))
               (define ok?
                 (case tool
                   [("appimagetool")
                    ;; appimagetool ships AS an AppImage; hosts without
                    ;; FUSE (CI runners, containers) must run it via
                    ;; self-extraction instead of a runtime mount.
                    (putenv "APPIMAGE_EXTRACT_AND_RUN" "1")
                    (run (find-executable-path "appimagetool" #f)
                         (path->string appdir)
                         (path->string appimage-path))]
                   [else
                    (putenv "OUTPUT" (path->string appimage-path))
                    (run (find-executable-path "linuxdeploy" #f)
                         "--appdir"
                         (path->string appdir)
                         "--output"
                         "appimage")]))
               (and ok? (file-exists? appimage-path) appimage-path))
             (lambda () (delete-tree-quietly! root))))))))
