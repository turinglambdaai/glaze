#lang racket/base

;; JSON API route tests: HTTP round trips through start-server's #:api —
;; method matching, :param capture, JSON body parsing (jsexpr uses SYMBOL
;; keys), error wrapping, static fallback, and run-app being composed from
;; the same pieces.

(require rackunit
         racket/file
         racket/string
         racket/port
         json
         net/http-client
         glaze/server
         glaze/api)

(define dir (make-temporary-file "glaze-api-~a" 'directory))
(call-with-output-file (build-path dir "index.html")
  (lambda (o) (display #"<html>idx</html>" o))
  #:exists 'replace)

(define count (box 0))

(define-values (port shutdown)
  (start-server
   #:port 18960
   #:public-dir dir
   #:api (list
          (GET "api/ping" (lambda (req) (hasheq 'pong #t)))
          (POST "api/bump/:delta"
                (lambda (req delta)
                  (set-box! count (+ (unbox count) (string->number delta)))
                  (hasheq 'count (unbox count))))
          (POST "api/echo"
                (lambda (req)
                  (define body (request-json-body req))
                  (hasheq 'echo (and (hash? body) (hash-ref body 'x 'miss)))))
          (GET "api/boom" (lambda (req) (raise-user-error 'boom "handler exploded")))
          (GET "api/raw" (lambda (req) (json-response (hasheq 'raw #t)))))))

(define (call method path [data #f])
  (define-values (status headers in)
    (http-sendrecv "127.0.0.1" path
                   #:port 18960
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers (if data '("Content-Type: application/json") '())))
  (define body (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status) body))

;; GET, jsexpr auto-wrapping.
(let-values ([(st body) (call "GET" "/api/ping")])
  (check-true (string-contains? st "200") "GET route matches")
  (check-equal? (bytes->jsexpr body) (hasheq 'pong #t) "jsexpr auto-wrapped"))

;; :param capture + state.
(let*-values ([(_1 b1) (call "POST" "/api/bump/5")]
              [(_2 b2) (call "POST" "/api/bump/7")])
  (check-equal? (hash-ref (bytes->jsexpr b1) 'count) 5 "param captured (5)")
  (check-equal? (hash-ref (bytes->jsexpr b2) 'count) 12 "state persists (12)"))

;; JSON body — jsexpr object keys are SYMBOLS.
(let-values ([(_ body) (call "POST" "/api/echo" #"{\"x\":42}")])
  (check-equal? (hash-ref (bytes->jsexpr body) 'echo) 42 "JSON body parsed, symbol keys"))

;; Handler exceptions become 500 JSON, not a crashed connection.
(let-values ([(st body) (call "GET" "/api/boom")])
  (check-true (string-contains? st "500") "handler raise -> 500")
  (check-true (hash? (bytes->jsexpr body)) "500 body is JSON"))

;; Full-response passthrough.
(let-values ([(st body) (call "GET" "/api/raw")])
  (check-true (string-contains? st "200") "raw response passthrough")
  (check-equal? (hash-ref (bytes->jsexpr body) 'raw) #t))

;; Method mismatch (GET on a POST route) falls through to static SPA fallback.
(let-values ([(st body) (call "GET" "/api/bump/5")])
  (check-true (string-contains? st "200") "method mismatch -> static fallback")
  (check-true (regexp-match? #rx#"idx" body) "static index served"))

;; Unmatched API path still serves static.
(let-values ([(st body) (call "GET" "/no-such")])
  (check-true (string-contains? st "200") "unknown path -> SPA fallback"))

(shutdown)
(delete-directory/files dir)

;; ---- run-app composition ----
(require glaze/app)
(check-equal? (procedure? run-app) #t "run-app is a procedure")

;; ---- route-match unit level ----
(define r (GET "a/:id/x" (lambda (req id) id)))
(check-equal? (route-match r 'GET '("a" "7" "x")) '("7") ":param captured by route-match")
(check-false (route-match r 'GET '("a" "7")) "length mismatch -> #f")
(check-false (route-match r 'POST '("a" "7" "x")) "method mismatch -> #f")
(check-false (route-match r 'GET '("b" "7" "x")) "literal segment mismatch -> #f")
