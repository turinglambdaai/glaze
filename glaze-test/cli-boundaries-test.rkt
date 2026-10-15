#lang racket/base

;; CLI orchestration stays thin: scaffold generation and native command runners
;; are directly testable without loading the dispatching `cli.rkt` module.

(require json
         racket/file
         racket/list
         rackunit
         glaze-cli/private/build-command
         glaze-cli/private/init
         glaze-cli/private/project
         glaze-cli/private/run
         glaze-cli/private/schema)

(test-case "build option parsing is isolated from platform staging"
  (define parsed
    (call-with-values (lambda ()
                        (parse-build-opts '("--name" "Demo"
                                                     "--version"
                                                     "1.2.3"
                                                     "--publisher"
                                                     "Acme"
                                                     "--identifier"
                                                     "com.acme.demo"
                                                     "--entry"
                                                     "app.rkt"
                                                     "--out"
                                                     "release"
                                                     "--installer"
                                                     "--embed-dlls"
                                                     "--url-scheme"
                                                     "demo"
                                                     "--url-scheme"
                                                     "demo-secure")))
                      list))
  (check-equal? (take parsed 8) '("Demo" "1.2.3" #f "app.rkt" "release" #t #t #f))
  (check-equal? (list-ref parsed 12) '("demo" "demo-secure"))
  (check-equal? (list-ref parsed 13) "Acme")
  (check-equal? (list-ref parsed 14) "com.acme.demo"))

(test-case "init owns one internally consistent project template"
  (define root (make-temporary-file "glaze-init-boundary-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-directory root]
                    [current-output-port (open-output-string)])
       (init-project "sample"))
     (define sample (build-path root "sample"))
     (for ([relative (in-list '("main.rkt" "glaze.rktd"
                                           "glaze-schema.json"
                                           "AGENTS.md"
                                           "verify.rkt"
                                           "public/index.html"))])
       (check-true (file-exists? (build-path sample relative))
                   (format "scaffold includes ~a" relative)))
     (check-equal? (hash-ref (project-schema-status sample) 'status) "ready")
     ;; Importing the configured binding must not enter module+ main.
     (check-equal? (dynamic-require (build-path sample "main.rkt") 'api) '())
     (define schema-output (open-output-string))
     (parameterize ([current-output-port schema-output])
       (check-equal? (run-schema-command '("check" "--json") sample) 0))
     (check-true (hash-ref (read-json (open-input-string (get-output-string schema-output)))
                           'compatible)))
   (lambda () (delete-directory/files root))))

(test-case "run helpers execute the project's exact files and preserve exit status"
  (define root (make-temporary-file "glaze-run-boundary-~a" 'directory))
  (dynamic-wind void
                (lambda ()
                  (call-with-output-file
                   (build-path root "main.rkt")
                   (lambda (out) (display "#lang racket/base\n(displayln \"dev-entry-ran\")\n" out)))
                  (call-with-output-file (build-path root "verify.rkt")
                                         (lambda (out) (display "#lang racket/base\n(exit 7)\n" out)))
                  (parameterize ([current-directory root]
                                 [current-output-port (open-output-string)])
                    (check-not-exn dev-app)
                    (check-equal? (verify-app) 7)))
                (lambda () (delete-directory/files root))))
