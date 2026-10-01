#lang racket/base

(require json
         net/http-client
         racket/file
         racket/port
         racket/string
         rackunit
         glaze/capability
         glaze/filesystem
         glaze/server)

(define root (make-temporary-file "glaze-filesystem-~a" 'directory))
(define outside (make-temporary-file "glaze-filesystem-outside-~a" 'directory))
(define text-path (build-path root "notes" "hello.txt"))
(define binary-path (build-path root "data.bin"))

;; Direct Racket API.
(fs-write-text! text-path "hello, Glaze")
(check-equal? (fs-read-text text-path) "hello, Glaze")
(fs-write-bytes! binary-path #"\0\1\2\377")
(check-equal? (fs-read-bytes binary-path) #"\0\1\2\377")
(check-true (fs-exists? text-path))
(check-equal? (hash-ref (fs-stat text-path) 'kind) "file")
(check-equal? (hash-ref (fs-stat text-path) 'size) 12)
(check-true (for/or ([entry (in-list (fs-read-dir root))])
              (string=? (hash-ref entry 'name) "notes")))

(define copy-path (build-path root "copies" "hello.txt"))
(define moved-path (build-path root "copies" "moved.txt"))
(fs-copy! text-path copy-path)
(check-equal? (fs-read-text copy-path) "hello, Glaze")
(fs-move! copy-path moved-path)
(check-false (fs-exists? copy-path))
(check-true (fs-exists? moved-path))
(fs-remove! moved-path)
(check-false (fs-exists? moved-path))

(define authority
  (make-capability "main"
                   (list (path-permission 'fs:read #:allow (list root))
                         (path-permission 'fs:write #:allow (list root)))))
(check-true (capability-authorized? authority 'fs:write (list text-path binary-path)))
(check-false
 (capability-authorized? authority 'fs:write (list text-path (build-path outside "escape.txt"))))

;; HTTP plugin routes use the same scope before invoking filesystem handlers.
(define token "filesystem-test-token")
(define-values (_port shutdown)
  (start-server #:port 18974
                #:public-dir root
                #:api-token token
                #:capability authority
                #:api (make-filesystem-routes)))

(define (call path body)
  (define-values (status headers in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port 18974
                   #:ssl? #f
                   #:method "POST"
                   #:data (string->bytes/utf-8 (jsexpr->string body))
                   #:headers (list "Content-Type: application/json"
                                   (string-append "X-Glaze-Token: " token))))
  (define response-bytes (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status)
          (and (positive? (bytes-length response-bytes)) (bytes->jsexpr response-bytes))))

(define http-text (build-path root "http" "message.txt"))
(let-values ([(status body) (call "/api/fs/write-text"
                                  (hasheq 'path (path->string http-text) 'text "from HTTP"))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref body 'ok)))
(let-values ([(status body) (call "/api/fs/read-text" (hasheq 'path (path->string http-text)))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref body 'text) "from HTTP"))

(let-values ([(status body) (call "/api/fs/read-file" (hasheq 'path (path->string binary-path)))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref body 'base64) "AAEC/w=="))

(define http-binary (build-path root "http" "roundtrip.bin"))
(let-values ([(status body) (call "/api/fs/write-file"
                                  (hasheq 'path (path->string http-binary) 'base64 "AAEC/w=="))])
  (check-true (string-contains? status "200"))
  (check-equal? (fs-read-bytes http-binary) #"\0\1\2\377"))

(define invalid-binary (build-path root "http" "invalid.bin"))
(let-values ([(status body) (call "/api/fs/write-file"
                                  (hasheq 'path (path->string invalid-binary) 'base64 "%%%"))])
  (check-true (string-contains? status "400"))
  (check-false (fs-exists? invalid-binary)))

(define http-copy (build-path root "http" "copy.txt"))
(let-values ([(status body)
              (call "/api/fs/copy"
                    (hasheq 'source (path->string http-text) 'destination (path->string http-copy)))])
  (check-true (string-contains? status "200"))
  (check-equal? (fs-read-text http-copy) "from HTTP"))

(define created-dir (build-path root "http" "created" "nested"))
(let-values ([(status body) (call "/api/fs/mkdir"
                                  (hasheq 'path (path->string created-dir) 'recursive #t))])
  (check-true (string-contains? status "200"))
  (check-true (directory-exists? created-dir)))

(define http-moved (build-path root "http" "moved.txt"))
(let-values ([(status body)
              (call
               "/api/fs/move"
               (hasheq 'source (path->string http-copy) 'destination (path->string http-moved)))])
  (check-true (string-contains? status "200"))
  (check-false (fs-exists? http-copy))
  (check-equal? (fs-read-text http-moved) "from HTTP"))

(let-values ([(status body) (call "/api/fs/exists" (hasheq 'path (path->string http-moved)))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref body 'exists)))

(define escaped-copy (build-path outside "copy.txt"))
(let-values ([(status body)
              (call
               "/api/fs/copy"
               (hasheq 'source (path->string http-text) 'destination (path->string escaped-copy)))])
  (check-true (string-contains? status "403"))
  (check-false (fs-exists? escaped-copy)))

(let-values ([(status body) (call "/api/fs/read-text"
                                  (hasheq 'path (path->string (build-path outside "secret.txt"))))])
  (check-true (string-contains? status "403")))

(let-values ([(status body) (call "/api/fs/read-dir" (hasheq 'path (path->string root)))])
  (check-true (string-contains? status "200"))
  (check-true (list? (hash-ref body 'entries))))

(let-values ([(status body) (call "/api/fs/stat" (hasheq 'path (path->string http-text)))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref body 'kind) "file"))

(let-values ([(status body) (call "/api/fs/remove" (hasheq 'path (path->string http-moved)))])
  (check-true (string-contains? status "200"))
  (check-false (fs-exists? http-moved)))

(shutdown)
(delete-directory/files root)
(delete-directory/files outside)
