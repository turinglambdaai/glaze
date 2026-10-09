#lang racket/base

(require db
         json
         net/http-client
         racket/file
         racket/port
         racket/string
         rackunit
         glaze/capability
         glaze/server
         glaze/sql)

(define root (make-temporary-file "glaze-sql-~a" 'directory))
(define database-path (build-path root "direct.db"))

(define database (open-sqlite-database database-path))
(check-true (sql-database? database))
(check-equal? (sql-database-path database) database-path)
(check-equal?
 (hash-ref
  (sql-execute! database
                "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, data BLOB, note TEXT)")
  'rowsAffected)
 0)
(define inserted
  (sql-execute! database
                "INSERT INTO items(name, data, note) VALUES (?, ?, ?)"
                (list "alpha" #"\0\1\377" sql-null)))
(check-equal? (hash-ref inserted 'rowsAffected) 1)
(check-equal? (hash-ref inserted 'lastInsertId) 1)
(define selected (sql-select database "SELECT id, name, data, note FROM items WHERE id = ?" '(1)))
(check-equal? (length selected) 1)
(check-equal? (hash-ref (car selected) 'name) "alpha")
(check-equal? (hash-ref (hash-ref (car selected) 'data) 'blobBase64) "AAH/")
(check-equal? (hash-ref (car selected) 'note) 'null)
(check-exn exn:fail? (lambda () (sql-select database "SELECT name FROM items" #:max-cell-bytes 3)))
(check-exn exn:fail? (lambda () (sql-select database "DELETE FROM items")))
(define second-insert (sql-execute! database "INSERT INTO items(name) VALUES ('beta')"))
(check-equal? (hash-ref second-insert 'rowsAffected) 1)
(check-exn exn:fail? (lambda () (sql-select database "SELECT * FROM items" #:max-rows 1)))
(sql-close! database)
(check-exn exn:fail? (lambda () (sql-select database "SELECT 1")))
(check-not-exn (lambda () (sql-close! database)))
(check-exn exn:fail? (lambda () (open-sqlite-database (build-path root "missing" "database.db"))))

(define route-root (build-path root "routes"))
(make-directory route-root)
(define route-database-path (build-path route-root "app.db"))
(define authority
  (make-capability "main"
                   (list (path-permission 'sql:load #:allow (list route-root))
                         (path-permission 'sql:select #:allow (list route-root))
                         (path-permission 'sql:execute #:allow (list route-root))
                         (path-permission 'sql:close #:allow (list route-root)))))
(define token "sql-test-token")
(define-values (_port shutdown)
  (start-server #:port 18982
                #:public-dir root
                #:api-token token
                #:capability authority
                #:api (make-sql-routes #:root route-root #:max-rows 5)))

(define (call endpoint body)
  (define-values (status headers input)
    (http-sendrecv "127.0.0.1"
                   (string-append "/api/sql/" endpoint)
                   #:port 18982
                   #:ssl? #f
                   #:method "POST"
                   #:data (string->bytes/utf-8 (jsexpr->string body))
                   #:headers (list "Content-Type: application/json"
                                   (string-append "X-Glaze-Token: " token))))
  (define response (port->bytes input))
  (close-input-port input)
  (values (bytes->string/utf-8 status)
          (and (positive? (bytes-length response)) (bytes->jsexpr response))))

(let-values ([(status body) (call "load" (hasheq 'path "app.db"))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref body 'loaded))
  (check-equal? (hash-ref body 'path) (path->string route-database-path)))
(let-values ([(status body)
              (call "execute"
                    (hasheq 'path
                            "app.db"
                            'query
                            "CREATE TABLE records (id INTEGER PRIMARY KEY, label TEXT, data BLOB)"))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref body 'rowsAffected) 0))
(let-values ([(status body) (call "execute"
                                  (hasheq 'path
                                          "app.db"
                                          'query
                                          "INSERT INTO records(label, data) VALUES (?, ?)"
                                          'params
                                          (list "first" (hasheq 'blobBase64 "AQID"))))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref body 'rowsAffected) 1)
  (check-equal? (hash-ref body 'lastInsertId) 1))
(let-values ([(status body) (call "select"
                                  (hasheq 'path
                                          "app.db"
                                          'query
                                          "SELECT id, label, data FROM records WHERE id = ?"
                                          'params
                                          '(1)))])
  (check-true (string-contains? status "200"))
  (define row (car (hash-ref body 'rows)))
  (check-equal? (hash-ref row 'label) "first")
  (check-equal? (hash-ref (hash-ref row 'data) 'blobBase64) "AQID"))
(let-values ([(status body) (call "select" (hasheq 'path "app.db" 'query "DELETE FROM records"))])
  (check-true (string-contains? status "500")))
(let-values ([(status body) (call "execute"
                                  (hasheq 'path
                                          "app.db"
                                          'query
                                          "INSERT INTO records(label) VALUES (?)"
                                          'params
                                          (list (hasheq 'blobBase64 "%%%"))))])
  (check-true (string-contains? status "400")))
(let-values ([(status body) (call "load" (hasheq 'path "../escape.db"))])
  (check-true (string-contains? status "403")))

(define-values (js-status js-headers js-input)
  (http-sendrecv "127.0.0.1" "/glaze/api.js" #:port 18982 #:ssl? #f #:method "GET"))
(define js (port->string js-input))
(close-input-port js-input)
(check-true (string-contains? js "sqlLoad"))
(check-true (string-contains? js "sqlSelect"))
(check-true (string-contains? js "sqlExecute"))
(check-true (string-contains? js "sqlClose"))

(let-values ([(status body) (call "close" (hasheq 'path "app.db"))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref body 'closed)))
(let-values ([(status body) (call "select" (hasheq 'path "app.db" 'query "SELECT 1"))])
  (check-true (string-contains? status "400")))

(shutdown)
(delete-directory/files root)
