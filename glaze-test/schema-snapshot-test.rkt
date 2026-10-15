#lang racket/base

(require json
         rackunit
         racket/file
         racket/list
         racket/runtime-path
         racket/string
         glaze/private/schema-snapshot
         glaze-cli/private/project
         glaze-cli/private/schema)

(define scalar-string (hasheq 'kind "scalar" 'name "String"))
(define scalar-int (hasheq 'kind "scalar" 'name "Int64"))
(define optional-string (hasheq 'kind "optional" 'element scalar-string))

(define base-command
  (hasheq 'name
          "save"
          'parameters
          (list (hasheq 'name "id" 'type scalar-int)
                (hasheq 'name "note" 'type optional-string))
          'result
          scalar-string
          'errors
          (list "invalid" "denied")))

(define base-record
  (hasheq 'name
          "Item"
          'fields
          (list (hasheq 'name "id" 'type scalar-int)
                (hasheq 'name "note" 'type optional-string))))

(define base-schema
  (hasheq 'contract
          1
          'id
          "glaze-routes"
          'revision
          1
          'commands
          (list base-command)
          'records
          (list base-record)
          'enums
          (list (hasheq 'name "Kind" 'cases (list "a" "b")))
          'events
          (list (hasheq 'name "changed" 'type scalar-string))
          'states
          (list (hasheq 'name "selection" 'type scalar-int))))

(define base
  (hasheq 'format
          "glaze-schema"
          'format-version
          1
          'glz
          1
          'routes
          (list (hasheq 'method "POST" 'path "/api/save"))
          'schema
          base-schema))

(define (with-schema snapshot key value)
  (hash-set snapshot 'schema (hash-set (hash-ref snapshot 'schema) key value)))

(define (report-codes snapshot [field 'breaking-changes])
  (map (lambda (item) (hash-ref item 'code))
       (hash-ref (schema-snapshot-report base snapshot) field)))

(define (breaking-code? snapshot code)
  (and (member code (report-codes snapshot)) #t))

(test-case "canonical JSON is deterministic and round-trips"
  (define left (hash 'z 1 'a (hash 'y 2 'b 3)))
  (define right (hasheq 'a (hasheq 'b 3 'y 2) 'z 1))
  (check-equal? (canonical-json-string left) (canonical-json-string right))
  (check-true (string-prefix? (canonical-json-string left) "{\n  \"a\":"))
  (check-equal? (read-json (open-input-string (canonical-json-string base))) base))

(test-case "protocol, routes, and schema metadata are compatibility gates"
  (check-true (breaking-code? (hash-set base 'glz 2) "metadata-changed"))
  (check-true (breaking-code? (hash-set base 'routes '()) "route-removed"))
  (check-true
   (breaking-code? (with-schema base 'revision 2) "schema-metadata-changed")))

(test-case "command compatibility covers identity, order, type, requiredness, result, and errors"
  (check-true (breaking-code? (with-schema base 'commands '()) "command-removed"))
  (define renamed (hash-set base-command 'name "store"))
  (check-true (breaking-code? (with-schema base 'commands (list renamed)) "command-removed"))
  (define reversed
    (hash-set base-command 'parameters (reverse (hash-ref base-command 'parameters))))
  (check-true
   (breaking-code? (with-schema base 'commands (list reversed)) "command-parameters-reordered"))
  (define changed-type
    (hash-set base-command
              'parameters
              (list (hasheq 'name "id" 'type scalar-string)
                    (hasheq 'name "note" 'type optional-string))))
  (check-true
   (breaking-code? (with-schema base 'commands (list changed-type))
                   "command-parameter-type-changed"))
  (define required-added
    (hash-update base-command
                 'parameters
                 (lambda (parameters)
                   (append parameters (list (hasheq 'name "force" 'type scalar-string))))))
  (check-true
   (breaking-code? (with-schema base 'commands (list required-added))
                   "required-command-parameter-added"))
  (check-true
   (breaking-code? (with-schema base
                                'commands
                                (list (hash-set base-command 'result scalar-int)))
                   "command-result-changed"))
  (check-true
   (breaking-code? (with-schema base
                                'commands
                                (list (hash-set base-command 'errors (list "invalid"))))
                   "command-error-removed"))
  (define optional-inserted
    (hash-set base-command
              'parameters
              (cons (hasheq 'name "tag" 'type optional-string)
                    (hash-ref base-command 'parameters))))
  (check-true
   (breaking-code? (with-schema base 'commands (list optional-inserted))
                   "command-parameter-added-out-of-order")))

(test-case "record and enum compatibility is conservative"
  (check-true (breaking-code? (with-schema base 'records '()) "record-removed"))
  (define missing-field
    (hash-set base-record 'fields (list (first (hash-ref base-record 'fields)))))
  (check-true
   (breaking-code? (with-schema base 'records (list missing-field)) "record-field-removed"))
  (define reordered
    (hash-set base-record 'fields (reverse (hash-ref base-record 'fields))))
  (check-true
   (breaking-code? (with-schema base 'records (list reordered)) "record-fields-reordered"))
  (define changed-field
    (hash-set base-record
              'fields
              (list (hasheq 'name "id" 'type scalar-string)
                    (hasheq 'name "note" 'type optional-string))))
  (check-true
   (breaking-code? (with-schema base 'records (list changed-field))
                   "record-field-type-changed"))
  (check-true
   (breaking-code? (with-schema base
                                'enums
                                (list (hasheq 'name "Kind" 'cases (list "b" "a"))))
                   "enums-changed"))
  (define optional-inserted
    (hash-set base-record
              'fields
              (cons (hasheq 'name "tag" 'type optional-string)
                    (hash-ref base-record 'fields))))
  (check-true
   (breaking-code? (with-schema base 'records (list optional-inserted))
                   "record-field-added-out-of-order")))

(test-case "event and state removals or type changes are breaking"
  (check-true (breaking-code? (with-schema base 'events '()) "events-removed"))
  (check-true
   (breaking-code? (with-schema base
                                'states
                                (list (hasheq 'name "selection" 'type scalar-string)))
                   "states-changed")))

(test-case "compatible additions are classified separately"
  (define optional-parameter-added
    (hash-update base-command
                 'parameters
                 (lambda (parameters)
                   (append parameters (list (hasheq 'name "tag" 'type optional-string))))))
  (define command-added (hasheq 'name "ping" 'parameters '() 'result scalar-string 'errors '()))
  (define optional-field-added
    (hash-update base-record
                 'fields
                 (lambda (fields)
                   (append fields (list (hasheq 'name "tag" 'type optional-string))))))
  (define next-schema
    (hash-set* base-schema
               'commands
               (list optional-parameter-added command-added)
               'records
               (list optional-field-added)))
  (define next
    (hash-set* base
               'routes
               (append (hash-ref base 'routes) (list (hasheq 'method "GET" 'path "/api/ping")))
               'schema
               next-schema))
  (define report (schema-snapshot-report base next))
  (check-true (hash-ref report 'compatible))
  (define codes (map (lambda (item) (hash-ref item 'code))
                     (hash-ref report 'compatible-additions)))
  (check-not-false (member "optional-command-parameter-added" codes))
  (check-not-false (member "optional-record-field-added" codes))
  (check-not-false (member "command-added" codes))
  (check-not-false (member "route-added" codes)))

(test-case "schema CLI writes, checks, and reports project readiness without launching the app"
  (define root (make-temporary-file "glaze-schema-cli-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file (build-path root "routes.rkt")
        (lambda (out)
          (display
           "#lang racket/base\n(require glaze)\n(displayln \"module noise must not corrupt JSON\")\n(define-api-routes api [(GET \"api/ping\") (ping) (hasheq 'ok #t)])\n(provide api)\n"
           out)))
      (call-with-output-file (build-path root "glaze.rktd")
        (lambda (out)
          (display
           "#hasheq((schema-module . \"routes.rkt\") (schema-binding . api) (schema-baseline . \"glaze-schema.json\"))\n"
           out)))
      (define write-output (open-output-string))
      (parameterize ([current-output-port write-output])
        (check-equal? (run-schema-command '("write" "--json") root) 0))
      (check-true
       (hash-ref (read-json (open-input-string (get-output-string write-output))) 'ok))
      (define check-output (open-output-string))
      (parameterize ([current-output-port check-output])
        (check-equal? (run-schema-command '("check" "--json") root) 0))
      (check-true
       (hash-ref (read-json (open-input-string (get-output-string check-output))) 'compatible))
      (check-true (file-exists? (build-path root "glaze-schema.json")))
      (check-equal? (hash-ref (project-schema-status root) 'status) "ready")
      (define baseline-path (build-path root "glaze-schema.json"))
      (define baseline (call-with-input-file baseline-path read-json))
      (call-with-output-file baseline-path
        (lambda (out) (display (canonical-json-string (hash-set baseline 'glz 2)) out))
        #:exists 'truncate/replace)
      (define output (open-output-string))
      (parameterize ([current-output-port output])
        (check-equal? (run-schema-command '("check" "--json") root) 1))
      (define report (read-json (open-input-string (get-output-string output))))
      (check-false (hash-ref report 'compatible))
      (check-equal? (hash-ref (first (hash-ref report 'breaking-changes)) 'code)
                    "metadata-changed"))
    (lambda () (delete-directory/files root))))
