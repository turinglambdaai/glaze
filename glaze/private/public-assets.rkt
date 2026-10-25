#lang racket/base

;; Static public-asset plumbing: the embedded default public directory and
;; the template/directory helpers around it. Internalized behind
;; glaze/private by G3-S2 (docs/api-stability.md) — never public API;
;; applications embed their own assets via their own `define-runtime-path`.

(require racket/file
         racket/path
         racket/runtime-path)

(provide embedded-public-dir
         public-dir-relative?
         ensure-public-dir
         copy-template)

;; The default embedded public assets directory. Declaring it here with
;; `define-runtime-path` means `raco distribute` copies it next to the
;; executable; packaged apps then serve from this directory at runtime.
;; The path is relative to this source file, so the `../` hop points at
;; glaze/public (an empty placeholder kept for library-level embedding;
;; per-app embedded assets come from the app's own `define-runtime-path`
;; declaration).
(define-runtime-path embedded-public-dir "../public")

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
