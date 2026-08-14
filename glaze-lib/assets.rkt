#lang racket/base

(require racket/port
         racket/file
         racket/path
         racket/runtime-path)

(provide copy-template
         ensure-public-dir
         resolve-public-dir
         embedded-public-dir
         public-dir-relative?)

;; Resolve the directory to serve static files from, in a way that survives
;; packaging. In dev, callers pass a relative "public" and it resolves against
;; `current-directory`. In a packaged app, callers pass the embedded directory
;; (declared via `define-runtime-path` below) so the app does not depend on the
;; working directory at runtime.
(define (resolve-public-dir dir)
  (if (complete-path? dir)
      dir
      (path->complete-path dir (current-directory))))

;; The default embedded public assets directory. Declaring it here with
;; `define-runtime-path` means `raco distribute` copies it next to the
;; executable; packaged apps then serve from this directory at runtime.
;; The path is relative to this source file, so it points at glaze-lib/public
;; (an empty placeholder kept for library-level embedding; per-app embedded
;; assets come from the app's own `define-runtime-path` declaration).
(define-runtime-path embedded-public-dir "public")

;; True if `path` is the embedded public dir (used by tests/build helpers).
(define (public-dir-relative? path)
  (and (path? path) #t))

(define (ensure-public-dir dir)
  (unless (directory-exists? dir)
    (make-directory dir))
  dir)

(define (copy-template src-dir dest-dir)
  (when (directory-exists? src-dir)
    (for ([f (in-directory src-dir)])
      (define rel (find-relative-path src-dir f))
      (define dest (build-path dest-dir rel))
      (unless (file-exists? dest)
        (make-parent-directory* dest)
        (copy-file f dest)))))

(define (make-parent-directory* path)
  (define dir (path-only path))
  (when dir
    (make-directory* dir)))
