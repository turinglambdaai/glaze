#lang racket/base

(require racket/path)

(provide resolve-public-dir)

;; Resolve the directory to serve static files from, in a way that survives
;; packaging. In dev, callers pass a relative "public" and it resolves against
;; `current-directory`. In a packaged app, callers pass the embedded directory
;; (glaze/private/public-assets declares the framework-level placeholder via
;; `define-runtime-path`) so the app does not depend on the working directory
;; at runtime.
(define (resolve-public-dir dir)
  (if (complete-path? dir)
      dir
      (path->complete-path dir (current-directory))))
