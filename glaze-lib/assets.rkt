#lang racket/base

(require racket/port
         racket/file
         racket/path)

(provide copy-template
         ensure-public-dir)

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
