#lang racket/base

(require json
         net/http-client
         racket/file
         racket/port
         racket/string
         rackunit
         glaze/api
         glaze/api-macros
         glaze/capability
         glaze/events
         glaze/server)

(define root (make-temporary-file "glaze-capability-~a" 'directory))
(define private-dir (build-path root "private"))
(make-directory private-dir)
(define outside (make-temporary-file "glaze-capability-outside-~a" 'directory))

(define authority
  (make-capability "main"
                   (list 'app:read
                         (path-permission 'fs:read #:allow (list root) #:deny (list private-dir))
                         (command-permission 'shell:execute
                                             #:allow '("git" "racket")
                                             #:deny '("racket")
                                             #:arguments (lambda (arguments)
                                                           (equal? arguments '("--version")))))))

(check-equal? (capability-id authority) "main")
(check-true (capability-has-permission? authority 'app:read))
(check-false (capability-has-permission? authority 'app:write))
(check-true (capability-authorized? authority 'app:read))
(check-true (capability-authorized? authority 'fs:read (build-path root "ok.txt")))
(check-false (capability-authorized? authority 'fs:read (build-path private-dir "secret.txt")))
(check-false (capability-authorized? authority 'fs:read (build-path outside "not-allowed.txt")))
(define linked-outside (build-path root "linked-outside"))
(define symlink-supported?
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (make-file-or-directory-link outside linked-outside)
    #t))
(when symlink-supported?
  (check-false (capability-authorized? authority 'fs:read (build-path linked-outside "escape.txt"))
               "an existing symlink cannot escape an allowed root"))
(check-true (capability-authorized? authority 'shell:execute (command-resource "git" '("--version"))))
(check-false (capability-authorized? authority 'shell:execute (command-resource "git" '("status"))))
(check-false
 (capability-authorized? authority 'shell:execute (command-resource "racket" '("--version"))))
(check-false
 (capability-authorized? authority 'shell:execute (command-resource "powershell" '("--version"))))
(check-false (capability-authorized? authority 'shell:execute (command-resource 42 '("--version"))))
(check-false (current-capability-id))
(check-exn exn:fail:contract?
           (lambda () (make-capability "duplicate" '(same same)))
           "duplicate grants cannot bypass scoped denials")

(define-api-routes
 typed-api
 [(POST "api/typed" #:permission 'app:read #:resource (lambda (req) 'typed-resource))
  (typed [value number?])
  (hasheq 'value value)])
(check-equal? (route-permission (car typed-api)) 'app:read)
(check-true (procedure? (route-resource (car typed-api))))

(check-exn exn:fail:contract?
           (lambda () (start-server #:port 18972 #:public-dir root #:api '() #:capability authority))
           "capability without token is rejected")
(check-exn
 exn:fail:contract?
 (lambda ()
   (start-server #:port 18972 #:public-dir root #:api '() #:api-token "" #:capability authority))
 "capability with an empty token is rejected")

(define handler-calls (box 0))
(define token "capability-test-token")
(define events (make-event-bus))
(define-values (_port shutdown)
  (start-server #:port 18972
                #:public-dir root
                #:api-token token
                #:capability authority
                #:events events
                #:api (list (GET "api/allowed"
                                 (lambda (req)
                                   (set-box! handler-calls (add1 (unbox handler-calls)))
                                   (hasheq 'capability (current-capability-id)))
                                 #:permission 'app:read)
                            (GET "api/not-granted"
                                 (lambda (req)
                                   (set-box! handler-calls (add1 (unbox handler-calls)))
                                   (hasheq 'bad #t))
                                 #:permission 'app:write)
                            (GET "api/unmarked"
                                 (lambda (req)
                                   (set-box! handler-calls (add1 (unbox handler-calls)))
                                   (hasheq 'bad #t)))
                            (POST "api/read-file"
                                  (lambda (req) (hasheq 'ok #t))
                                  #:permission 'fs:read
                                  #:resource (lambda (req)
                                               (hash-ref (request-json-body req) 'path))))))

(define (call method path #:data [data #f] #:token? [token? #t])
  (define headers
    (append (if data
                '("Content-Type: application/json")
                '())
            (if token?
                (list (string-append "X-Glaze-Token: " token))
                '())))
  (define-values (status response-headers in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port 18972
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers headers))
  (define body (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status) body))

(let-values ([(status body) (call "GET" "/api/allowed" #:token? #f)])
  (check-true (string-contains? status "401")))

(let-values ([(status body) (call "GET" "/api/allowed")])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref (bytes->jsexpr body) 'capability) "main"))

(let-values ([(status body) (call "GET" "/api/not-granted")])
  (check-true (string-contains? status "403")))
(let-values ([(status body) (call "GET" "/api/unmarked")])
  (check-true (string-contains? status "403")))
(let-values ([(status body) (call "GET" "/glaze/events")])
  (check-true (string-contains? status "403")))
(check-equal? (unbox handler-calls) 1 "denied handlers never run")

(define allowed-json
  (string->bytes/utf-8 (jsexpr->string (hasheq 'path (path->string (build-path root "ok.txt"))))))
(define denied-json
  (string->bytes/utf-8
   (jsexpr->string (hasheq 'path (path->string (build-path private-dir "secret.txt"))))))
(let-values ([(status body) (call "POST" "/api/read-file" #:data allowed-json)])
  (check-true (string-contains? status "200")))
(let-values ([(status body) (call "POST" "/api/read-file" #:data denied-json)])
  (check-true (string-contains? status "403")))

;; The generated client exposes only routes whose declared permissions exist
;; in the active capability. Scope is enforced later, per request.
(let-values ([(status body) (call "GET" "/glaze/api.js" #:token? #f)])
  (check-true (string-contains? status "200"))
  (define js (bytes->string/utf-8 body))
  (check-true (string-contains? js "allowed"))
  (check-true (string-contains? js "readFile"))
  (check-false (string-contains? js "notGranted"))
  (check-false (string-contains? js "unmarked")))

(shutdown)
(delete-directory/files root)
(delete-directory/files outside)
