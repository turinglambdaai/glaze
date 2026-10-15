#lang racket/base

;; `raco glaze schema`: materialize the application's runtime contract and
;; compare it with the committed baseline without starting a server or native
;; window.

(require json
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         glaze/private/schema-snapshot
         glaze-cli/private/project)

(provide run-schema-command
         project-schema-status)

(struct schema-options (action module binding baseline json?) #:transparent)

(define (option-value who flag args)
  (unless (pair? (cdr args))
    (raise-user-error who "~a requires a value" flag))
  (cadr args))

(define (parse-options args)
  (unless (pair? args)
    (raise-user-error
     'schema
     "usage: raco glaze schema <write|check> [--module <path>] [--binding <name>] [--baseline <path>] [--json]"))
  (define action (car args))
  (unless (member action '("write" "check"))
    (raise-user-error 'schema "expected `write` or `check`, got: ~a" action))
  (let loop ([remaining (cdr args)]
             [module #f]
             [binding #f]
             [baseline #f]
             [json? #f])
    (cond
      [(null? remaining) (schema-options action module binding baseline json?)]
      [(equal? (car remaining) "--module")
       (define value (option-value 'schema "--module" remaining))
       (loop (cddr remaining) value binding baseline json?)]
      [(equal? (car remaining) "--binding")
       (define value (option-value 'schema "--binding" remaining))
       (loop (cddr remaining) module value baseline json?)]
      [(equal? (car remaining) "--baseline")
       (define value (option-value 'schema "--baseline" remaining))
       (loop (cddr remaining) module binding value json?)]
      [(equal? (car remaining) "--json") (loop (cdr remaining) module binding baseline #t)]
      [else (raise-user-error 'schema "unexpected argument: ~a" (car remaining))])))

(define (binding-symbol value)
  (cond
    [(symbol? value) value]
    [(string? value) (string->symbol value)]
    [else (raise-user-error 'schema "schema-binding must be a symbol or string")]))

(define (settings root options)
  (define config (read-project-config root))
  (define module-value
    (or (schema-options-module options) (project-config-ref config 'schema-module #f)))
  (unless module-value
    (raise-user-error 'schema
                      "schema module is not configured; add schema-module to ~a or pass --module"
                      project-config-name))
  (define binding-value
    (or (schema-options-binding options) (project-config-ref config 'schema-binding 'api)))
  (define baseline-value
    (or (schema-options-baseline options)
        (project-config-ref config 'schema-baseline "glaze-schema.json")))
  (values (project-path root module-value)
          (binding-symbol binding-value)
          (project-path root baseline-value)))

(define (load-current-snapshot module-path binding)
  (unless (file-exists? module-path)
    (raise-user-error 'schema "schema module does not exist: ~a" (path->string module-path)))
  (define routes
    (with-handlers ([exn:fail? (lambda (error)
                                 (raise-user-error 'schema
                                                   "cannot load ~a from ~a: ~a"
                                                   binding
                                                   (path->string module-path)
                                                   (exn-message error)))])
      (parameterize ([current-output-port (open-output-nowhere)]
                     [current-error-port (open-output-nowhere)])
        (dynamic-require module-path binding))))
  (unless (list? routes)
    (raise-user-error 'schema
                      "~a from ~a must be a Glaze route list"
                      binding
                      (path->string module-path)))
  (with-handlers ([exn:fail? (lambda (error)
                               (raise-user-error 'schema
                                                 "cannot build schema from ~a: ~a"
                                                 (path->string module-path)
                                                 (exn-message error)))])
    (schema-snapshot routes)))

(define (read-baseline path)
  (unless (file-exists? path)
    (raise-user-error 'schema
                      "schema baseline does not exist: ~a (run `raco glaze schema write`)"
                      (path->string path)))
  (with-handlers ([exn:fail? (lambda (error)
                               (raise-user-error 'schema
                                                 "invalid schema baseline ~a: ~a"
                                                 (path->string path)
                                                 (exn-message error)))])
    (call-with-input-file path read-json)))

(define (write-baseline path snapshot)
  (define parent (path-only path))
  (when parent
    (make-directory* parent))
  (call-with-atomic-output-file path
                                (lambda (out _temporary-path)
                                  (display (canonical-json-string snapshot) out))))

(define (path-text path)
  (path->string (simplify-path path #t)))

(define (error-report action message)
  (hasheq 'contract-version
          1
          'action
          action
          'ok
          #f
          'error
          (hasheq 'code "schema-command-failed" 'message message)))

(define (emit-json value)
  (write-json value)
  (newline))

(define (run-schema-command args [root (current-directory)])
  (define json-requested? (member "--json" args))
  (with-handlers ([exn:fail? (lambda (error)
                               (if json-requested?
                                   (emit-json (error-report (if (pair? args)
                                                                (car args)
                                                                "unknown")
                                                            (exn-message error)))
                                   (eprintf "schema: ~a\n" (exn-message error)))
                               2)])
    (define options (parse-options args))
    (define-values (module-path binding baseline-path) (settings root options))
    (define current (load-current-snapshot module-path binding))
    (cond
      [(equal? (schema-options-action options) "write")
       (write-baseline baseline-path current)
       (define report
         (hasheq 'contract-version
                 1
                 'action
                 "write"
                 'ok
                 #t
                 'module
                 (path-text module-path)
                 'binding
                 (symbol->string binding)
                 'baseline
                 (path-text baseline-path)))
       (if (schema-options-json? options)
           (emit-json report)
           (printf "Wrote Glaze schema baseline: ~a\n" (path-text baseline-path)))
       0]
      [else
       (define baseline (read-baseline baseline-path))
       (define compatibility (schema-snapshot-report baseline current))
       (define ok? (hash-ref compatibility 'compatible))
       (define report
         (hash-set* compatibility
                    'contract-version
                    1
                    'action
                    "check"
                    'ok
                    ok?
                    'module
                    (path-text module-path)
                    'binding
                    (symbol->string binding)
                    'baseline
                    (path-text baseline-path)))
       (if (schema-options-json? options)
           (emit-json report)
           (begin
             (printf "Glaze schema: ~a\n" (if ok? "compatible" "BREAKING"))
             (for ([item (in-list (hash-ref report 'breaking-changes))])
               (printf "  - [~a] ~a\n" (hash-ref item 'code) (hash-ref item 'message)))
             (for ([item (in-list (hash-ref report 'compatible-additions))])
               (printf "  + [~a] ~a\n" (hash-ref item 'code) (hash-ref item 'message)))))
       (if ok? 0 1)])))
