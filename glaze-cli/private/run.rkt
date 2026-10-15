#lang racket/base

;; Native application runners shared by CLI dispatch. Neither command offers a
;; browser-only fallback.

(require racket/file
         racket/system)

(provide dev-app
         verify-app)

;; `dev` runs the project's real entry point, so routes/events/window options
;; in main.rkt are preserved. Glaze development follows the same native GUI
;; path as the shipped application; there is no browser-mode escape hatch.
;; The Racket interpreter for dev/verify: PATH lookup first, then the
;; running Racket itself — package-build sandboxes invoke racket by
;; absolute path and have no bin directory on PATH.
(define (racket-executable)
  (or (find-executable-path "racket" #f)
      (let ([self (find-system-path 'exec-file)]) (and (file-exists? self) self))))

(define (dev-app)
  (define entry (build-path (current-directory) "main.rkt"))
  (unless (file-exists? entry)
    (error 'dev
           "main.rkt not found in ~a; run this command from a Glaze project"
           (path->string (current-directory))))
  (define racket-exe (racket-executable))
  (unless racket-exe
    (error 'dev "racket executable not found on PATH"))
  (printf "Starting Glaze native app: ~a\n" (path->string entry))
  (define code (system*/exit-code racket-exe (path->string entry)))
  (unless (zero? code)
    (exit code)))

(define (verify-app)
  (define verifier (build-path (current-directory) "verify.rkt"))
  (unless (file-exists? verifier)
    (error 'verify
           "verify.rkt not found; add a native UI acceptance script or rerun `raco glaze init`"))
  (define racket-exe (or (racket-executable) (error 'verify "racket executable not found on PATH")))
  (system*/exit-code racket-exe (path->string verifier)))
