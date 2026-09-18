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

;; Candidate roots for a relative asset directory. Development keeps the
;; current directory first. Packaged executables additionally look beside the
;; executable and, for a canonical macOS bundle, in ../Resources.
(define (runtime-asset-roots)
  (define cwd (current-directory))
  (define run-file
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (find-system-path 'run-file)))
  (define exe-dir
    (and (path? run-file)
         (path-only (path->complete-path run-file))))
  (filter values
          (list cwd
                exe-dir
                (and exe-dir
                     (simplify-path (build-path exe-dir ".." "Resources") #f)))))

;; Resolve the directory to serve static files from without changing the
;; process working directory. For an existing relative path, prefer the
;; developer's current directory. When that path is absent (the common case
;; for apps launched from Finder/Explorer), try locations relative to the
;; packaged executable. If nothing exists yet, preserve the historical
;; behavior by returning the current-directory resolution.
(define (resolve-public-dir dir)
  (define p
    (cond
      [(path? dir) dir]
      [(string? dir) (string->path dir)]
      [else (raise-argument-error 'resolve-public-dir "(or/c path? string?)" dir)]))
  (cond
    [(complete-path? p) (simplify-path p #f)]
    [else
     (or (for/or ([root (in-list (runtime-asset-roots))])
           (define candidate (simplify-path (build-path root p) #f))
           (and (directory-exists? candidate) candidate))
         (simplify-path (path->complete-path p (current-directory)) #f))]))

;; The default embedded public assets directory. Declaring it here with
;; `define-runtime-path` means `raco distribute` copies it next to the
;; executable; packaged apps then serve from this directory at runtime.
;; The path is relative to this source file, so it points at glaze/public
;; (an empty placeholder kept for library-level embedding; per-app embedded
;; assets can also come from an app's own `define-runtime-path` declaration).
(define-runtime-path embedded-public-dir "public")

;; Historical predicate retained for compatibility.
(define (public-dir-relative? path)
  (and (path? path) #t))

(define (ensure-public-dir dir)
  (unless (directory-exists? dir)
    (make-directory* dir))
  dir)

(define (copy-template src-dir dest-dir)
  (when (directory-exists? src-dir)
    (for ([f (in-directory src-dir)]
          #:when (file-exists? f))
      (define rel (find-relative-path src-dir f))
      (define dest (build-path dest-dir rel))
      (unless (file-exists? dest)
        (make-parent-directory* dest)
        (copy-file f dest)))))

(define (make-parent-directory* path)
  (define dir (path-only path))
  (when dir
    (make-directory* dir)))
