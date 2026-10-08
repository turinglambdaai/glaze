#lang racket/base

(require json
         net/http-client
         racket/file
         racket/path
         racket/port
         racket/string
         rackunit
         glaze/capability
         glaze/path
         glaze/server)

(define root (make-temporary-file "glaze-path-~a" 'directory))
(define resources (build-path root "resources"))
(define outside (make-temporary-file "glaze-path-outside-~a" 'directory))
(make-directory resources)
(call-with-output-file (build-path resources "asset.txt") (lambda (out) (display "asset" out)))

(for ([directory (in-list (list (config-dir)
                                (data-dir)
                                (local-data-dir)
                                (cache-dir)
                                (home-dir)
                                (temp-dir)
                                (desktop-dir)
                                (document-dir)
                                (download-dir)
                                (audio-dir)
                                (picture-dir)
                                (video-dir)
                                (public-dir)
                                (template-dir)
                                (font-dir)
                                (executable-dir)))])
  (check-true (complete-path? directory)))

(when (eq? (system-type 'os) 'unix)
  (define previous-xdg-config (getenv "XDG_CONFIG_HOME"))
  (dynamic-wind
   (lambda ()
     (putenv "XDG_CONFIG_HOME" (path->string root))
     (call-with-output-file (build-path root "user-dirs.dirs")
                            (lambda (out) (display "XDG_DOWNLOAD_DIR=\"$HOME/GlazeDownloads\"\n" out))
                            #:exists 'truncate/replace))
   (lambda () (check-equal? (download-dir) (build-path (home-dir) "GlazeDownloads")))
   (lambda () (putenv "XDG_CONFIG_HOME" previous-xdg-config))))

(define default-resolver (make-path-resolver "com.example.glaze" #:resource-root resources))
(for ([directory (in-list (list (app-config-dir default-resolver)
                                (app-data-dir default-resolver)
                                (app-local-data-dir default-resolver)
                                (app-cache-dir default-resolver)
                                (app-log-dir default-resolver)))])
  (check-true (complete-path? directory)))
(check-equal? (path-basename (app-data-dir default-resolver)) "com.example.glaze")

(define portable
  (make-path-resolver "com.example.glaze" #:resource-root resources #:app-directories-override root))
(check-equal? (app-config-dir portable) (simplify-path root #f))
(check-equal? (app-data-dir portable) (simplify-path root #f))
(check-equal? (app-local-data-dir portable) (simplify-path root #f))
(check-equal? (app-cache-dir portable) (build-path root "caches"))
(check-equal? (app-log-dir portable) (build-path root "logs"))

(define selective
  (make-path-resolver "com.example.glaze"
                      #:resource-root resources
                      #:app-directories-override
                      (hasheq 'data "$TEMP/glaze-data" 'cache (build-path root "custom-cache"))))
(check-equal? (app-data-dir selective) (build-path (temp-dir) "glaze-data"))
(check-equal? (app-cache-dir selective) (build-path root "custom-cache"))
(check-exn exn:fail:contract? (lambda () (make-path-resolver "../escape")))

(check-equal? (resolve-resource portable "asset.txt") (build-path resources "asset.txt"))
(check-exn exn:fail? (lambda () (resolve-resource portable "../escape.txt")))
(define linked-outside (build-path resources "linked-outside"))
(define symlink-supported?
  (with-handlers ([exn:fail? (lambda (error) #f)])
    (make-file-or-directory-link outside linked-outside)
    #t))
(when symlink-supported?
  (check-exn exn:fail?
             (lambda () (resolve-resource portable (build-path "linked-outside" "secret.txt")))))

(check-equal? (path-basename (build-path "one" "two.txt")) "two.txt")
(check-equal? (path-extname "two.txt") ".txt")
(check-equal? (path-dirname (build-path "one" "two.txt")) (path->string (string->path "one")))
(check-true (path-absolute? root))
(check-false (path-absolute? "relative.txt"))
(check-equal? (path-normalize (build-path "one" 'up "two")) (string->path "two"))
(check-equal? (path-join "one" "two") (build-path "one" "two"))
(check-true (complete-path? (path-resolve "one" "two")))
(check-not-false (member path-separator '("/" "\\")))
(check-not-false (member path-delimiter '(":" ";")))

(define authority
  (make-capability "main"
                   (list (path-permission 'path:app-data #:allow (list root))
                         (path-permission 'path:resource #:allow (list resources))
                         'path:join
                         'path:normalize
                         'path:is-absolute)))
(define token "path-test-token")
(define-values (_port shutdown)
  (start-server #:port 18979
                #:public-dir root
                #:api-token token
                #:capability authority
                #:api (make-path-routes #:app-id "com.example.glaze"
                                        #:resource-root resources
                                        #:app-directories-override root)))

(define (call method path [body #f] #:token? [token? #t])
  (define data (and body (string->bytes/utf-8 (jsexpr->string body))))
  (define-values (status headers in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port 18979
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers (append (if data
                                         '("Content-Type: application/json")
                                         '())
                                     (if token?
                                         (list (string-append "X-Glaze-Token: " token))
                                         '()))))
  (define response (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status) response))

(let-values ([(status body) (call "GET" "/api/path/app-data-dir")])
  (check-true (string-contains? status "200"))
  (check-equal? (string->path (hash-ref (bytes->jsexpr body) 'path)) (simplify-path root #f)))
(let-values ([(status body) (call "POST" "/api/path/join" (hasheq 'paths '("one" "two")))])
  (check-true (string-contains? status "200"))
  (check-equal? (string->path (hash-ref (bytes->jsexpr body) 'path)) (build-path "one" "two")))
(let-values ([(status body) (call "POST" "/api/path/resolve-resource" (hasheq 'path "asset.txt"))])
  (check-true (string-contains? status "200"))
  (check-equal? (string->path (hash-ref (bytes->jsexpr body) 'path))
                (build-path resources "asset.txt")))
(let-values ([(status body)
              (call "POST" "/api/path/resolve-resource" (hasheq 'path "../escape.txt"))])
  (check-true (string-contains? status "403")))
(let-values ([(status body) (call "GET" "/api/path/home-dir")])
  (check-true (string-contains? status "403")))
(let-values ([(status body) (call "GET" "/glaze/api.js" #f #:token? #f)])
  (define js (bytes->string/utf-8 body))
  (check-true (string-contains? js "pathAppDataDir"))
  (check-true (string-contains? js "pathResolveResource"))
  (check-true (string-contains? js "pathJoin"))
  (check-false (string-contains? js "pathHomeDir")))

(shutdown)
(delete-directory/files root)
(delete-directory/files outside)
