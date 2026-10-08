#lang racket/base

(require json
         net/http-client
         racket/file
         racket/port
         racket/string
         rackunit
         glaze/capability
         glaze/server
         glaze/system)

(define info (system-information))
(for ([key (in-list '(arch exeExtension family locale osType platform version))])
  (check-true (string? (hash-ref info key))))
(check-not-false (member (hash-ref info 'platform) '("windows" "macos" "linux")))
(check-true (positive? (string-length (system-hostname))))

(define root (make-temporary-file "glaze-system-plugin-~a" 'directory))
(define outside (make-temporary-file "glaze-system-plugin-outside-~a" 'directory))
(define authority
  (make-capability "main"
                   (list 'os:read
                         (path-permission 'opener:open-path #:allow (list root))
                         (path-permission 'opener:reveal-path #:allow (list root))
                         (url-permission 'opener:open-url
                                         #:allow (list "https://allowed.example/path")))))
(define token "system-plugin-token")
(define-values (_port shutdown)
  (start-server #:port 18978
                #:public-dir root
                #:api-token token
                #:capability authority
                #:api (make-system-routes)))

(define (call method path [body #f] #:token? [token? #t])
  (define data (and body (string->bytes/utf-8 (jsexpr->string body))))
  (define-values (status headers in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port 18978
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers (append (if data
                                         '("Content-Type: application/json")
                                         '())
                                     (if token?
                                         (list (string-append "X-Glaze-Token: " token))
                                         '()))))
  (define response-bytes (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status) response-bytes))

(let-values ([(status body) (call "GET" "/api/system/os/info")])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref (bytes->jsexpr body) 'platform) (hash-ref info 'platform)))
(let-values ([(status body) (call "GET" "/api/system/os/hostname")])
  (check-true (string-contains? status "403")))
(let-values ([(status body) (call "GET" "/api/system/clipboard/read")])
  (check-true (string-contains? status "403")))
(let-values ([(status body) (call "POST"
                                  "/api/system/opener/open-url"
                                  (hasheq 'url "https://not-allowed.example/path"))])
  (check-true (string-contains? status "403")))
(let-values ([(status body) (call "POST"
                                  "/api/system/opener/open-path"
                                  (hasheq 'path
                                          (path->string (build-path outside "not-allowed.txt"))))])
  (check-true (string-contains? status "403")))
(let-values ([(status body) (call "GET" "/api/system/os/info" #f #:token? #f)])
  (check-true (string-contains? status "401")))
(let-values ([(status body) (call "GET" "/glaze/api.js" #f #:token? #f)])
  (define js (bytes->string/utf-8 body))
  (check-true (string-contains? js "systemOsInfo"))
  (check-true (string-contains? js "systemOpenerOpenUrl"))
  (check-false (string-contains? js "systemOsHostname"))
  (check-false (string-contains? js "systemClipboardRead")))

(shutdown)
(delete-directory/files root)
(delete-directory/files outside)
