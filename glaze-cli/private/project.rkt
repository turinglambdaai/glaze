#lang racket/base

;; Read-only project metadata shared by `inspect` and schema tooling.  The
;; configuration is a plain datum, never evaluated, so inspecting an unknown
;; checkout cannot execute project code.

(require racket/file
         racket/path)

(provide project-config-name
         read-project-config
         project-config-ref
         project-path
         project-schema-status)

(define project-config-name "glaze.rktd")

(define (complete-root root)
  (simplify-path (path->complete-path root) #t))

(define (read-project-config [root (current-directory)])
  (define path (build-path (complete-root root) project-config-name))
  (and (file-exists? path)
       (call-with-input-file path
         (lambda (input)
           (define value
             (parameterize ([read-accept-reader #f]
                            [read-accept-lang #f]
                            [read-accept-compiled #f])
               (read input)))
           (unless (hash? value)
             (raise-user-error 'glaze-project
                               "~a must contain one hash datum"
                               (path->string path)))
           (unless (eof-object?
                    (parameterize ([read-accept-reader #f]
                                   [read-accept-lang #f]
                                   [read-accept-compiled #f])
                      (read input)))
             (raise-user-error 'glaze-project
                               "~a must contain exactly one datum"
                               (path->string path)))
           value))))

(define (project-config-ref config key [default #f])
  (cond
    [(not config) default]
    [(hash-has-key? config key) (hash-ref config key)]
    [(hash-has-key? config (symbol->string key)) (hash-ref config (symbol->string key))]
    [else default]))

(define (project-path root value)
  (and value
       (let ([path (if (path? value) value (string->path value))])
         (simplify-path
          (if (absolute-path? path)
              path
              (build-path (complete-root root) path))
          #t))))

(define (path-text path)
  (path->string (simplify-path path #t)))

(define (file-entry root relative)
  (define path (and relative (project-path root relative)))
  (hasheq 'path (and relative (if (path? relative) (path->string relative) relative))
          'absolute (and path (path-text path))
          'exists (and path (file-exists? path))))

(define (project-schema-status [root (current-directory)])
  (with-handlers ([exn:fail?
                   (lambda (error)
                     (hasheq 'configured #f
                             'status "invalid-config"
                             'config (file-entry root project-config-name)
                             'diagnostic (exn-message error)))])
    (define config (read-project-config root))
    (define module-value (project-config-ref config 'schema-module #f))
    (define binding-value (project-config-ref config 'schema-binding 'api))
    (define baseline-value (project-config-ref config 'schema-baseline "glaze-schema.json"))
    (define module-entry (file-entry root module-value))
    (define baseline-entry (file-entry root baseline-value))
    (hasheq 'configured
            (and config module-value #t)
            'status
            (cond
              [(not config) "missing-config"]
              [(not module-value) "missing-schema-module"]
              [(not (hash-ref module-entry 'exists)) "missing-module"]
              [(not (hash-ref baseline-entry 'exists)) "missing-baseline"]
              [else "ready"])
            'config
            (file-entry root project-config-name)
            'module
            module-entry
            'binding
            (if (symbol? binding-value) (symbol->string binding-value) binding-value)
            'baseline
            baseline-entry)))
