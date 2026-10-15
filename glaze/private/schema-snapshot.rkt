#lang racket/base

;; Deterministic, transport-neutral contract snapshots for Glaze apps.  The
;; snapshot is deliberately derived from build-hello: runtime negotiation,
;; generated clients, and CI compatibility checks therefore share one source
;; of truth.

(require json
         racket/list
         racket/string
         "../bridge.rkt")

(provide schema-snapshot-format-version
         schema-snapshot
         schema-snapshot-compatible?
         schema-snapshot-report
         write-canonical-json
         canonical-json-string)

(define schema-snapshot-format-version 1)

(define (schema-snapshot routes)
  (define hello (build-hello routes #f route->js-name))
  (hasheq 'format
          "glaze-schema"
          'format-version
          schema-snapshot-format-version
          'glz
          (hash-ref hello 'glz)
          'routes
          (hash-ref hello 'routes)
          'schema
          (hash-ref hello 'schema)))

;; json's compact writer does not promise object traversal order.  Stable key
;; ordering keeps committed baselines reviewable and byte-identical across
;; Racket hash implementations and platforms.
(define (json-key-string key)
  (cond
    [(symbol? key) (symbol->string key)]
    [(string? key) key]
    [else (raise-argument-error 'write-canonical-json "JSON object key" key)]))

(define (write-indent out depth)
  (display (make-string (* depth 2) #\space) out))

(define (write-scalar value out)
  (write-json value out))

(define (write-canonical-json value [out (current-output-port)] [depth 0])
  (cond
    [(hash? value)
     (define pairs
       (sort (hash->list value) string<? #:key (lambda (pair) (json-key-string (car pair)))))
     (if (null? pairs)
         (display "{}" out)
         (begin
           (display "{\n" out)
           (for ([pair (in-list pairs)] [index (in-naturals)])
             (unless (zero? index) (display ",\n" out))
             (write-indent out (add1 depth))
             (write-json (json-key-string (car pair)) out)
             (display ": " out)
             (write-canonical-json (cdr pair) out (add1 depth)))
           (display "\n" out)
           (write-indent out depth)
           (display "}" out)))]
    [(list? value)
     (if (null? value)
         (display "[]" out)
         (begin
           (display "[\n" out)
           (for ([item (in-list value)] [index (in-naturals)])
             (unless (zero? index) (display ",\n" out))
             (write-indent out (add1 depth))
             (write-canonical-json item out (add1 depth)))
           (display "\n" out)
           (write-indent out depth)
           (display "]" out)))]
    [else (write-scalar value out)]))

(define (canonical-json-string value)
  (define out (open-output-string))
  (write-canonical-json value out)
  (display "\n" out)
  (get-output-string out))

(define missing (gensym 'missing))

(define (jref object key [default missing])
  (define string-key (if (symbol? key) (symbol->string key) key))
  (define symbol-key (if (string? key) (string->symbol key) key))
  (cond
    [(and (hash? object) (hash-has-key? object symbol-key)) (hash-ref object symbol-key)]
    [(and (hash? object) (hash-has-key? object string-key)) (hash-ref object string-key)]
    [(eq? default missing) (error 'schema-snapshot-report "missing field: ~a" string-key)]
    [else default]))

(define (named-index entries)
  (for/hash ([value (in-list entries)])
    (values (jref value 'name) value)))

(define (optional-type? value)
  (and (hash? value) (equal? (jref value 'kind #f) "optional")))

(define (change code path message)
  (hasheq 'code code 'path path 'message message))

(define (schema-snapshot-report old new)
  (define breaking '())
  (define additions '())
  (define (break! code path message)
    (set! breaking (cons (change code path message) breaking)))
  (define (add! code path message)
    (set! additions (cons (change code path message) additions)))

  (define (same! object-key path)
    (unless (equal? (jref old object-key #f) (jref new object-key #f))
      (break! "metadata-changed" path (format "~a changed" path))))

  (same! 'format "format")
  (same! 'format-version "format-version")
  (same! 'glz "glz")

  (define old-schema (jref old 'schema (hash)))
  (define new-schema (jref new 'schema (hash)))
  (for ([key (in-list '(contract id revision))])
    (unless (equal? (jref old-schema key #f) (jref new-schema key #f))
      (break! "schema-metadata-changed"
              (format "schema.~a" key)
              (format "schema ~a changed" key))))

  (define old-routes
    (for/hash ([route (in-list (jref old 'routes '()))])
      (values (format "~a ~a" (jref route 'method) (jref route 'path)) route)))
  (define new-routes
    (for/hash ([route (in-list (jref new 'routes '()))])
      (values (format "~a ~a" (jref route 'method) (jref route 'path)) route)))
  (for ([route-key (in-list (sort (hash-keys old-routes) string<?))])
    (unless (hash-has-key? new-routes route-key)
      (break! "route-removed" (format "routes.~a" route-key) (format "route removed: ~a" route-key))))
  (for ([route-key (in-list (sort (hash-keys new-routes) string<?))]
        #:unless (hash-has-key? old-routes route-key))
    (add! "route-added" (format "routes.~a" route-key) (format "route added: ~a" route-key)))

  (define (compare-named-simple collection #:addition-compatible? [addition-compatible? #t])
    (define old-values (named-index (jref old-schema collection '())))
    (define new-values (named-index (jref new-schema collection '())))
    (for ([name (in-list (sort (hash-keys old-values) string<?))])
      (cond
        [(not (hash-has-key? new-values name))
         (break! (format "~a-removed" collection)
                 (format "schema.~a.~a" collection name)
                 (format "~a removed: ~a" collection name))]
        [(not (equal? (hash-ref old-values name) (hash-ref new-values name)))
         (break! (format "~a-changed" collection)
                 (format "schema.~a.~a" collection name)
                 (format "~a changed: ~a" collection name))]))
    (for ([name (in-list (sort (hash-keys new-values) string<?))]
          #:unless (hash-has-key? old-values name))
      ((if addition-compatible? add! break!)
       (format "~a-added" collection)
       (format "schema.~a.~a" collection name)
       (format "~a added: ~a" collection name))))

  ;; Enums are closed sets.  Adding a case can make an old exhaustive client
  ;; fail, so any enum change is breaking.  New named enums are harmless until
  ;; referenced by an existing surface.
  (compare-named-simple 'enums)
  (compare-named-simple 'events)
  (compare-named-simple 'states)

  (define old-records (named-index (jref old-schema 'records '())))
  (define new-records (named-index (jref new-schema 'records '())))
  (for ([name (in-list (sort (hash-keys old-records) string<?))])
    (define base-path (format "schema.records.~a" name))
    (cond
      [(not (hash-has-key? new-records name))
       (break! "record-removed" base-path (format "record removed: ~a" name))]
      [else
       (define old-fields (jref (hash-ref old-records name) 'fields '()))
       (define new-fields (jref (hash-ref new-records name) 'fields '()))
       (define old-names (map (lambda (field) (jref field 'name)) old-fields))
       (define new-names (map (lambda (field) (jref field 'name)) new-fields))
       (define old-field-map (named-index old-fields))
       (define new-field-map (named-index new-fields))
       (for ([field-name (in-list old-names)])
         (cond
           [(not (hash-has-key? new-field-map field-name))
            (break! "record-field-removed"
                    (format "~a.fields.~a" base-path field-name)
                    (format "record field removed: ~a.~a" name field-name))]
           [(not (equal? (jref (hash-ref old-field-map field-name) 'type)
                         (jref (hash-ref new-field-map field-name) 'type)))
            (break! "record-field-type-changed"
                    (format "~a.fields.~a.type" base-path field-name)
                    (format "record field type changed: ~a.~a" name field-name))]))
       (define existing-new-order (filter (lambda (field-name) (member field-name old-names)) new-names))
       (unless (equal? existing-new-order old-names)
         (break! "record-fields-reordered" (format "~a.fields" base-path)
                 (format "record fields reordered: ~a" name)))
       (when (and (> (length new-names) (length old-names))
                  (not (equal? (take new-names (length old-names)) old-names)))
         (break! "record-field-added-out-of-order"
                 (format "~a.fields" base-path)
                 (format "new record fields must be appended: ~a" name)))
       (for ([field-name (in-list new-names)]
             #:unless (hash-has-key? old-field-map field-name))
         (define field (hash-ref new-field-map field-name))
         (if (optional-type? (jref field 'type))
             (add! "optional-record-field-added"
                   (format "~a.fields.~a" base-path field-name)
                   (format "optional record field added: ~a.~a" name field-name))
             (break! "required-record-field-added"
                     (format "~a.fields.~a" base-path field-name)
                     (format "required record field added: ~a.~a" name field-name))))]))
  (for ([name (in-list (sort (hash-keys new-records) string<?))]
        #:unless (hash-has-key? old-records name))
    (add! "record-added" (format "schema.records.~a" name) (format "record added: ~a" name)))

  (define old-commands (named-index (jref old-schema 'commands '())))
  (define new-commands (named-index (jref new-schema 'commands '())))
  (for ([name (in-list (sort (hash-keys old-commands) string<?))])
    (define base-path (format "schema.commands.~a" name))
    (cond
      [(not (hash-has-key? new-commands name))
       (break! "command-removed" base-path (format "command removed: ~a" name))]
      [else
       (define old-command (hash-ref old-commands name))
       (define new-command (hash-ref new-commands name))
       (unless (equal? (jref old-command 'result) (jref new-command 'result))
         (break! "command-result-changed" (format "~a.result" base-path)
                 (format "command result changed: ~a" name)))
       (define old-params (jref old-command 'parameters '()))
       (define new-params (jref new-command 'parameters '()))
       (define old-names (map (lambda (param) (jref param 'name)) old-params))
       (define new-names (map (lambda (param) (jref param 'name)) new-params))
       (define old-param-map (named-index old-params))
       (define new-param-map (named-index new-params))
       (for ([param-name (in-list old-names)])
         (cond
           [(not (hash-has-key? new-param-map param-name))
            (break! "command-parameter-removed"
                    (format "~a.parameters.~a" base-path param-name)
                    (format "command parameter removed: ~a.~a" name param-name))]
           [(not (equal? (jref (hash-ref old-param-map param-name) 'type)
                         (jref (hash-ref new-param-map param-name) 'type)))
            (break! "command-parameter-type-changed"
                    (format "~a.parameters.~a.type" base-path param-name)
                    (format "command parameter type changed: ~a.~a" name param-name))]))
       (define existing-new-order (filter (lambda (param-name) (member param-name old-names)) new-names))
       (unless (equal? existing-new-order old-names)
         (break! "command-parameters-reordered" (format "~a.parameters" base-path)
                 (format "command parameters reordered: ~a" name)))
       (when (and (> (length new-names) (length old-names))
                  (not (equal? (take new-names (length old-names)) old-names)))
         (break! "command-parameter-added-out-of-order"
                 (format "~a.parameters" base-path)
                 (format "new command parameters must be appended: ~a" name)))
       (for ([param-name (in-list new-names)]
             #:unless (hash-has-key? old-param-map param-name))
         (define parameter (hash-ref new-param-map param-name))
         (if (optional-type? (jref parameter 'type))
             (add! "optional-command-parameter-added"
                   (format "~a.parameters.~a" base-path param-name)
                   (format "optional command parameter added: ~a.~a" name param-name))
             (break! "required-command-parameter-added"
                     (format "~a.parameters.~a" base-path param-name)
                     (format "required command parameter added: ~a.~a" name param-name))))
       (define old-errors (jref old-command 'errors '()))
       (define new-errors (jref new-command 'errors '()))
       (for ([code (in-list old-errors)] #:unless (member code new-errors))
         (break! "command-error-removed" (format "~a.errors.~a" base-path code)
                 (format "command error removed: ~a.~a" name code)))
       (for ([code (in-list new-errors)] #:unless (member code old-errors))
         (add! "command-error-added" (format "~a.errors.~a" base-path code)
               (format "command error added: ~a.~a" name code)))]))
  (for ([name (in-list (sort (hash-keys new-commands) string<?))]
        #:unless (hash-has-key? old-commands name))
    (add! "command-added" (format "schema.commands.~a" name) (format "command added: ~a" name)))

  (hasheq 'compatible (null? breaking)
          'breaking-changes (reverse breaking)
          'compatible-additions (reverse additions)))

(define (schema-snapshot-compatible? old new)
  (hash-ref (schema-snapshot-report old new) 'compatible))
