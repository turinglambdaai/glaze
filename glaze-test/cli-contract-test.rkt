#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system)

(define raco
  (or (find-executable-path
       (if (eq? (system-type 'os) 'windows) "raco.exe" "raco")
       #f)
      (error 'cli-test "raco not found")))

(define (run-glaze . args)
  ;; Keep expected CLI error diagnostics out of the test runner's output while
  ;; still checking the real registered raco command in a subprocess.
  (define out (open-output-string))
  (define err (open-output-string))
  (define code
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (apply system*/exit-code raco "glaze" args)))
  (values code (get-output-string out) (get-output-string err)))

(let-values ([(code _out _err) (run-glaze "build" "--name")])
  (check-not-equal? code 0 "missing build option value fails"))

(let-values ([(code _out _err) (run-glaze "build" "--definitely-unknown")])
  (check-not-equal? code 0 "unknown build option fails"))

(let-values ([(code _out _err) (run-glaze "keygen" "--unknown")])
  (check-not-equal? code 0 "unknown keygen option fails"))

(let-values ([(code _out _err)
              (run-glaze "license" "verify" "--pub" "x.pem"
                         "--product" "X" "--unknown")])
  (check-not-equal? code 0 "unknown license option fails"))

(let-values ([(code _out _err) (run-glaze "init" "one" "two")])
  (check-not-equal? code 0 "init rejects extra project paths"))

;; Scaffold a real project and make sure the generated entry follows the
;; recommended run-app/module+ main path rather than the historical browser
;; server template.
(define tmp (make-temporary-file "glaze-cli-~a" 'directory))
(define project (build-path tmp "sample"))
(let-values ([(code _out err) (run-glaze "init" (path->string project))])
  (check-equal? code 0 (format "init succeeds: ~a" err)))
(define main-text (file->string (build-path project "main.rkt")))
(check-true (string-contains? main-text "(module+ main"))
(check-true (string-contains? main-text "(run-app"))
(check-false (string-contains? main-text "start-dev-server"))
(delete-directory/files tmp)
