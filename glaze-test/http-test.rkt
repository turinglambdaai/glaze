#lang racket/base

(require json
         net/http-client
         racket/file
         racket/port
         racket/string
         rackunit
         web-server/http/request-structs
         web-server/http/response-structs
         glaze/api
         glaze/capability
         glaze/http
         glaze/server)

(define root (make-temporary-file "glaze-http-~a" 'directory))
(define secret-calls (box 0))
(define (incoming-header req wanted)
  (for/or ([value (in-list (request-headers/raw req))])
    (and (string-ci=? (bytes->string/utf-8 (header-field value)) wanted)
         (bytes->string/utf-8 (header-value value)))))
(define (redirect location)
  (response/full 302
                 #"Found"
                 (current-seconds)
                 #"text/plain"
                 (list (header #"Location" (string->bytes/utf-8 location)))
                 '(#"redirect")))
(define target-routes
  (list
   (GET "api/hello" (lambda (req) (hasheq 'message "hello")))
   (POST "api/echo" (lambda (req) (request-json-body req)))
   (GET
    "api/binary"
    (lambda (req)
      (response/full 200 #"OK" (current-seconds) #"application/octet-stream" '() '(#"\0\1\2\377"))))
   (GET "api/large" (lambda (req) (hasheq 'text (make-string 4096 #\x))))
   (GET "api/slow"
        (lambda (req)
          (sleep 0.2)
          (hasheq 'ok #t)))
   (GET "api/redirect-ok" (lambda (req) (redirect "/api/hello")))
   (GET "api/redirect-cross-origin" (lambda (req) (redirect "http://localhost:18980/api/auth")))
   (GET "api/auth"
        (lambda (req) (hasheq 'authorization (or (incoming-header req "Authorization") 'null))))
   (GET "api/redirect-denied" (lambda (req) (redirect "/api/secret")))
   (GET "api/secret"
        (lambda (req)
          (set-box! secret-calls (add1 (unbox secret-calls)))
          (hasheq 'secret #t)))))
(define-values (_target-port shutdown-target)
  (start-server #:port 18980 #:public-dir root #:api target-routes))

(define hello-url "http://127.0.0.1:18980/api/hello")
(define echo-url "http://127.0.0.1:18980/api/echo")
(define binary-url "http://127.0.0.1:18980/api/binary")
(define large-url "http://127.0.0.1:18980/api/large")
(define slow-url "http://127.0.0.1:18980/api/slow")
(define redirect-ok-url "http://127.0.0.1:18980/api/redirect-ok")
(define redirect-cross-origin-url "http://127.0.0.1:18980/api/redirect-cross-origin")
(define redirect-denied-url "http://127.0.0.1:18980/api/redirect-denied")

(define hello (http-request hello-url))
(check-equal? (hash-ref hello 'status) 200)
(check-true (string-contains? (hash-ref hello 'bodyText) "hello"))
(check-false (hash-ref hello 'redirected))
(define echo
  (http-request echo-url
                #:method 'POST
                #:headers (hasheq 'Content-Type "application/json")
                #:body "{\"value\":42}"))
(check-equal? (hash-ref (string->jsexpr (hash-ref echo 'bodyText)) 'value) 42)
(check-equal? (hash-ref (http-request binary-url) 'bodyBase64) "AAEC/w==")
(check-exn exn:fail? (lambda () (http-request large-url #:max-response-bytes 128)))
(check-exn exn:fail? (lambda () (http-request slow-url #:timeout 0.05)))
(define redirected (http-request redirect-ok-url))
(check-true (hash-ref redirected 'redirected))
(check-equal? (hash-ref redirected 'url) hello-url)
(define cross-origin
  (http-request redirect-cross-origin-url #:headers (hasheq 'Authorization "Bearer secret")))
(check-equal? (hash-ref (string->jsexpr (hash-ref cross-origin 'bodyText)) 'authorization) 'null)
(check-exn exn:fail?
           (lambda ()
             (http-request redirect-denied-url
                           #:authorize-url? (lambda (url) (string=? url redirect-denied-url)))))
(check-equal? (unbox secret-calls) 0)
(check-exn exn:fail? (lambda () (http-request hello-url #:headers (hasheq 'Host "example.com"))))
(check-exn exn:fail? (lambda () (http-request "http://?")))

(define authority
  (make-capability
   "main"
   (list
    (url-permission
     'http:request
     #:allow
     (list hello-url echo-url binary-url large-url slow-url redirect-ok-url redirect-denied-url)))))
(define token "http-test-token")
(define-values (_bridge-port shutdown-bridge)
  (start-server #:port 18981
                #:public-dir root
                #:api-token token
                #:capability authority
                #:api (make-http-routes #:max-response-bytes 8192 #:timeout 1)))

(define (call body)
  (define-values (status headers input)
    (http-sendrecv "127.0.0.1"
                   "/api/http/request"
                   #:port 18981
                   #:ssl? #f
                   #:method "POST"
                   #:data (string->bytes/utf-8 (jsexpr->string body))
                   #:headers (list "Content-Type: application/json"
                                   (string-append "X-Glaze-Token: " token))))
  (define response (port->bytes input))
  (close-input-port input)
  (values (bytes->string/utf-8 status)
          (and (positive? (bytes-length response)) (bytes->jsexpr response))))

(let-values ([(status body) (call (hasheq 'url hello-url))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref body 'status) 200)
  (check-true (string-contains? (hash-ref body 'bodyText) "hello")))
(let-values ([(status body) (call (hasheq 'url redirect-ok-url))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref body 'redirected))
  (check-equal? (hash-ref body 'url) hello-url))
(let-values ([(status body) (call (hasheq 'url redirect-denied-url))])
  (check-true (string-contains? status "500")))
(check-equal? (unbox secret-calls) 0 "redirect targets are re-authorized before following")
(let-values ([(status body) (call (hasheq 'url "http://127.0.0.1:18980/api/secret"))])
  (check-true (string-contains? status "403")))
(let-values ([(status body) (call (hasheq 'url echo-url 'bodyBase64 "%%%"))])
  (check-true (string-contains? status "400")))
(let-values ([(status body) (call (hasheq 'url hello-url 'headers (hasheq 'Host "bad")))])
  (check-true (string-contains? status "400")))

(define-values (js-status js-headers js-input)
  (http-sendrecv "127.0.0.1" "/glaze/api.js" #:port 18981 #:ssl? #f #:method "GET"))
(define js (port->string js-input))
(close-input-port js-input)
(check-true (string-contains? js "httpRequest"))

(shutdown-bridge)
(shutdown-target)
(delete-directory/files root)
