#lang racket/base

;; Portable archive fallback shared by every installer path: produce a .zip or
;; .tar.gz of a distribution when no native installer toolchain exists. This
;; is a distribution-format degradation, deliberately unlike the GUI runtime's
;; fail-hard contract.

(require racket/file
         racket/path
         "build-tools.rkt")

(provide archive-directory)

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
       [else
        (displayln "[glaze] No zip tool found; skipping archive." (current-error-port))
        #f])]
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
