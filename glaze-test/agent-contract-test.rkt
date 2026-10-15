#lang racket/base

(require json
         rackunit
         racket/file
         glaze-cli/inspect)

(test-case "project report is a serializable versioned contract"
  (define root (make-temporary-file "glaze-agent-contract-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (make-directory (build-path root "public"))
     (for ([relative (in-list '("main.rkt" "verify.rkt" "AGENTS.md"))])
       (call-with-output-file (build-path root relative) void))
     (define report (project-report root))
     (check-equal? (hash-ref report 'contract-version) 1)
     (check-equal? (hash-ref report 'principles) '("Human-first" "Agent-native" "Local by design"))
     (define app (hash-ref report 'application))
     (check-true (hash-ref (hash-ref app 'entry) 'exists))
     (check-true (hash-ref (hash-ref app 'frontend) 'exists))
     (check-equal? (hash-ref (hash-ref report 'schema) 'status) "missing-config")
     (check-not-false
      (member "schema-check" (map (lambda (item) (hash-ref item 'name)) (hash-ref report 'commands))))
     (check-not-exn (lambda () (write-json report (open-output-string)))))
   (lambda () (delete-directory/files root))))
