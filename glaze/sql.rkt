#lang racket/base

;; Capability-scoped SQLite access for Racket and the embedded frontend.

(require db
         json
         net/base64
         racket/file
         racket/list
         racket/path
         racket/string
         "api.rkt"
         "capability.rkt")

(provide sql-database?
         sql-database-path
         open-sqlite-database
         sql-select
         sql-execute!
         sql-close!
         make-sql-routes)

(struct sql-database (path connection lock [closed? #:mutable]) #:transparent)

(define default-max-connections 16)
(define default-max-rows 10000)
(define default-max-cell-bytes (* 10 1024 1024))
(define max-query-bytes (* 1024 1024))
(define max-parameters 10000)

(define (ensure-database who database)
  (unless (sql-database? database)
    (raise-argument-error who "sql-database?" database))
  (when (sql-database-closed? database)
    (raise-arguments-error who "database is closed" "path" (sql-database-path database))))

(define (open-sqlite-database path #:busy-retry-limit [busy-retry-limit 1000])
  (unless (path-string? path)
    (raise-argument-error 'open-sqlite-database "path-string?" path))
  (unless (exact-nonnegative-integer? busy-retry-limit)
    (raise-argument-error 'open-sqlite-database "exact-nonnegative-integer?" busy-retry-limit))
  (define complete-path (path->complete-path path))
  (define parent (path-only complete-path))
  (unless (and parent (directory-exists? parent))
    (raise-arguments-error 'open-sqlite-database
                           "parent directory does not exist"
                           "path"
                           complete-path))
  (sql-database
   complete-path
   (sqlite3-connect #:database complete-path #:mode 'create #:busy-retry-limit busy-retry-limit)
   (make-semaphore 1)
   #f))

(define (normalize-query who statement)
  (unless (string? statement)
    (raise-argument-error who "string?" statement))
  (when (> (bytes-length (string->bytes/utf-8 statement)) max-query-bytes)
    (raise-arguments-error who "SQL statement exceeds 1 MiB"))
  (define normalized (string-trim statement))
  (when (string=? normalized "")
    (raise-arguments-error who "SQL statement is empty"))
  normalized)

(define (normalize-parameters who parameters)
  (unless (and (list? parameters) (<= (length parameters) max-parameters))
    (raise-argument-error who "list with at most 10000 values" parameters))
  parameters)

(define (sql-value->json value maximum)
  (define (bounded-string text)
    (when (> (bytes-length (string->bytes/utf-8 text)) maximum)
      (raise-arguments-error 'sql-select "result cell exceeds configured byte limit" "limit" maximum))
    text)
  (cond
    [(sql-null? value) 'null]
    [(bytes? value)
     (when (> (bytes-length value) maximum)
       (raise-arguments-error 'sql-select
                              "result cell exceeds configured byte limit"
                              "limit"
                              maximum))
     (hasheq 'blobBase64 (bytes->string/utf-8 (base64-encode value #"")))]
    [(string? value) (bounded-string value)]
    [(or (boolean? value) (real? value)) value]
    [else (bounded-string (format "~a" value))]))

(define select-query-rx #px"(?i:^\uFEFF?[[:space:]]*(?:select|with)\\b)")

(define (sql-select database
                    statement
                    [parameters '()]
                    #:max-rows [max-rows default-max-rows]
                    #:max-cell-bytes [max-cell-bytes default-max-cell-bytes])
  (ensure-database 'sql-select database)
  (unless (exact-positive-integer? max-rows)
    (raise-argument-error 'sql-select "exact-positive-integer?" max-rows))
  (unless (exact-positive-integer? max-cell-bytes)
    (raise-argument-error 'sql-select "exact-positive-integer?" max-cell-bytes))
  (define query-text (normalize-query 'sql-select statement))
  (unless (regexp-match? select-query-rx query-text)
    (raise-arguments-error 'sql-select "only SELECT or WITH queries are allowed" "query" statement))
  (define arguments (normalize-parameters 'sql-select parameters))
  (define wrapped-query
    (format "SELECT * FROM (~a) AS glaze_query LIMIT ~a"
            (regexp-replace #px";[[:space:]]*$" query-text "")
            (add1 max-rows)))
  (call-with-semaphore
   (sql-database-lock database)
   (lambda ()
     (ensure-database 'sql-select database)
     (define result (apply query (sql-database-connection database) wrapped-query arguments))
     (unless (rows-result? result)
       (raise-arguments-error 'sql-select "query did not return rows" "query" statement))
     (define rows (rows-result-rows result))
     (when (> (length rows) max-rows)
       (raise-arguments-error 'sql-select "result exceeds configured row limit" "limit" max-rows))
     (define names
       (for/list ([header (in-list (rows-result-headers result))])
         (string->symbol (cdr (assq 'name header)))))
     (for/list ([row (in-list rows)])
       (for/hasheq ([name (in-list names)]
                    [value (in-vector row)])
         (values name (sql-value->json value max-cell-bytes)))))))

(define (result-info-ref result key [default #f])
  (define found (assq key (simple-result-info result)))
  (if found
      (cdr found)
      default))

(define (sql-execute! database statement [parameters '()])
  (ensure-database 'sql-execute! database)
  (define query-text (normalize-query 'sql-execute! statement))
  (define arguments (normalize-parameters 'sql-execute! parameters))
  (call-with-semaphore
   (sql-database-lock database)
   (lambda ()
     (ensure-database 'sql-execute! database)
     (define result (apply query (sql-database-connection database) query-text arguments))
     (unless (simple-result? result)
       (raise-arguments-error 'sql-execute! "statement unexpectedly returned rows" "query" statement))
     (hasheq 'rowsAffected
             (or (result-info-ref result 'affected-rows) 0)
             'lastInsertId
             (or (result-info-ref result 'insert-id) 'null)))))

(define (sql-close! database)
  (unless (sql-database? database)
    (raise-argument-error 'sql-close! "sql-database?" database))
  (call-with-semaphore (sql-database-lock database)
                       (lambda ()
                         (unless (sql-database-closed? database)
                           (disconnect (sql-database-connection database))
                           (set-sql-database-closed?! database #t))))
  (void))

(define missing (gensym 'missing))

(define (bad-parameter message)
  (raise (exn:fail:glaze:bad-param message (current-continuation-marks))))

(define (body-hash req)
  (define body (request-json-body req))
  (unless (hash? body)
    (bad-parameter "body: expected a JSON object"))
  body)

(define (body-ref body key predicate)
  (define value (hash-ref body key missing))
  (cond
    [(eq? value missing) (bad-parameter (format "~a: missing" key))]
    [(predicate value) value]
    [else (bad-parameter (format "~a: invalid value ~v" key value))]))

(define (body-option body key predicate default)
  (define value (hash-ref body key default))
  (if (predicate value)
      value
      (bad-parameter (format "~a: invalid value ~v" key value))))

(define base64-rx #px"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")

(define (json-parameter value)
  (cond
    [(eq? value 'null) sql-null]
    [(or (string? value) (boolean? value) (real? value)) value]
    [(and (hash? value)
          (= (hash-count value) 1)
          (string? (hash-ref value 'blobBase64 #f))
          (regexp-match? base64-rx (hash-ref value 'blobBase64)))
     (with-handlers ([exn:fail? (lambda (error) (bad-parameter "params: invalid blobBase64"))])
       (base64-decode (string->bytes/utf-8 (hash-ref value 'blobBase64))))]
    [else (bad-parameter (format "params: unsupported SQL value ~v" value))]))

(define (make-sql-routes #:root root
                         #:prefix [prefix "api/sql"]
                         #:max-connections [max-connections default-max-connections]
                         #:max-rows [max-rows default-max-rows]
                         #:max-cell-bytes [max-cell-bytes default-max-cell-bytes]
                         #:busy-retry-limit [busy-retry-limit 1000])
  (unless (path-string? root)
    (raise-argument-error 'make-sql-routes "path-string?" root))
  (unless (and (string? prefix) (not (string=? prefix "")))
    (raise-argument-error 'make-sql-routes "non-empty-string?" prefix))
  (unless (exact-positive-integer? max-connections)
    (raise-argument-error 'make-sql-routes "exact-positive-integer?" max-connections))
  (unless (exact-positive-integer? max-rows)
    (raise-argument-error 'make-sql-routes "exact-positive-integer?" max-rows))
  (unless (exact-positive-integer? max-cell-bytes)
    (raise-argument-error 'make-sql-routes "exact-positive-integer?" max-cell-bytes))
  (unless (exact-nonnegative-integer? busy-retry-limit)
    (raise-argument-error 'make-sql-routes "exact-nonnegative-integer?" busy-retry-limit))
  (define complete-root (path->complete-path root))
  (unless (directory-exists? complete-root)
    (raise-arguments-error 'make-sql-routes "root directory does not exist" "root" complete-root))
  (define root-authority
    (make-capability "sql-root" (list (path-permission 'sql:path #:allow (list complete-root)))))
  (define registry (make-hash))
  (define registry-lock (make-semaphore 1))
  ;; Request custodians end after each response. Connections must live for the
  ;; route set's lifetime so later select/execute calls can reuse them.
  (define database-custodian (make-custodian))
  (define (endpoint name)
    (string-append (string-trim prefix "/") "/" name))
  (define (resolve-path body)
    (define requested (body-ref body 'path path-string?))
    (when (complete-path? requested)
      (bad-parameter "path: expected a path relative to the configured SQL root"))
    (define resolved (path->complete-path requested complete-root))
    (unless (capability-authorized? root-authority 'sql:path resolved)
      (bad-parameter "path: outside the configured SQL root"))
    resolved)
  (define (path-resource req)
    (resolve-path (body-hash req)))
  (define (cache-key path)
    (cons (current-capability-id) (path->string (simplify-path path #f))))
  (define (database-for body)
    (define path (resolve-path body))
    (define key (cache-key path))
    (call-with-semaphore registry-lock
                         (lambda ()
                           (or (hash-ref registry key #f)
                               (bad-parameter "path: database is not loaded for this capability")))))
  (define (parameters body)
    (map json-parameter
         (body-option body
                      'params
                      (lambda (value) (and (list? value) (<= (length value) max-parameters)))
                      '())))
  (list (POST (endpoint "load")
              (lambda (req)
                (define body (body-hash req))
                (define path (resolve-path body))
                (define key (cache-key path))
                (define database
                  (call-with-semaphore
                   registry-lock
                   (lambda ()
                     (or (hash-ref registry key #f)
                         (begin
                           (when (>= (hash-count registry) max-connections)
                             (raise-arguments-error 'make-sql-routes
                                                    "connection registry is full"
                                                    "limit"
                                                    max-connections))
                           (let ([opened
                                  (parameterize ([current-custodian database-custodian])
                                    (open-sqlite-database path #:busy-retry-limit busy-retry-limit))])
                             (hash-set! registry key opened)
                             opened))))))
                (hasheq 'path (path->string (sql-database-path database)) 'loaded #t))
              #:permission 'sql:load
              #:resource path-resource)
        (POST (endpoint "select")
              (lambda (req)
                (define body (body-hash req))
                (hasheq 'rows
                        (sql-select (database-for body)
                                    (body-ref body 'query string?)
                                    (parameters body)
                                    #:max-rows (body-option body
                                                            'maxRows
                                                            (lambda (value)
                                                              (and (exact-positive-integer? value)
                                                                   (<= value max-rows)))
                                                            max-rows)
                                    #:max-cell-bytes max-cell-bytes)))
              #:permission 'sql:select
              #:resource path-resource)
        (POST (endpoint "execute")
              (lambda (req)
                (define body (body-hash req))
                (sql-execute! (database-for body) (body-ref body 'query string?) (parameters body)))
              #:permission 'sql:execute
              #:resource path-resource)
        (POST (endpoint "close")
              (lambda (req)
                (define body (body-hash req))
                (define path (resolve-path body))
                (define key (cache-key path))
                (define database
                  (call-with-semaphore registry-lock (lambda () (hash-ref registry key #f))))
                (when database
                  (sql-close! database)
                  (call-with-semaphore registry-lock (lambda () (hash-remove! registry key))))
                (hasheq 'closed (and database #t)))
              #:permission 'sql:close
              #:resource path-resource)))
