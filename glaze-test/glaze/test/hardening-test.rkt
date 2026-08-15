#lang racket/base

;; Hardening suite: API token (header/cookie channels, 401, api.js
;; bootstrap), on-error reporting through the 500 path, and update
;; checking (semver + manifest over HTTP).

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/string
         json
         net/http-client
         glaze/server
         glaze/api
         glaze/api-macros
         glaze/events
         glaze/app
         glaze/update)

;; ---- token ----
(define token (make-api-token))
(check-true (regexp-match? #px"^[0-9a-f]{32}$" token) "token is 32 hex chars")
(check-false (string=? (make-api-token) token) "tokens are random")

(define-values (port shutdown)
  (start-server #:port 18995
                #:public-dir "/tmp"
                #:api (list (GET "api/ping" (lambda (req) (hasheq 'pong #t))))
                #:api-token token))

(define (call path #:headers [headers '()] #:port [p 18995])
  (define-values (st h in)
    (http-sendrecv "127.0.0.1" path #:port p #:ssl? #f
                   #:headers headers))
  (define b (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 st) h b))

;; no token -> 401
(let*-values ([(_s1 _h1 _b1) (call "/api/ping")])
  (check-true (string-contains? _s1 "401") "no token -> 401"))
;; wrong token -> 401
(let*-values ([(_s2 _h2 _b2) (call "/api/ping" #:headers (list "X-Glaze-Token: wrong"))])
  (check-true (string-contains? _s2 "401") "wrong token -> 401"))
;; header channel
(let*-values ([(_s3 _h3 _b3)
               (call "/api/ping" #:headers (list (format "X-Glaze-Token: ~a" token)))])
  (check-true (string-contains? _s3 "200") "header token -> 200"))
;; api.js bootstrap sets the cookie
(let*-values ([(_s4 h4 _b4) (call "/glaze/api.js")])
  (define set-cookie
    (for/or ([hh (in-list h4)])
      (define s (bytes->string/latin-1 hh))
      (and (string-prefix? (string-downcase s) "set-cookie:")
           (string-trim (substring s (string-length "Set-Cookie:"))))))
  (check-true (and set-cookie
                   (string-contains? set-cookie (format "glaze_token=~a" token)))
              "api.js sets glaze_token cookie")
  ;; cookie channel: replay the Set-Cookie value as a Cookie header
  (define cookie-header (car (string-split set-cookie ";")))
  (let*-values ([(_s5 _h5 _b5) (call "/api/ping"
                         #:headers (list (string-append "Cookie: " cookie-header)))])
    (check-true (string-contains? _s5 "200") "cookie token -> 200")))

;; ---- on-error reporting through the 500 path ----
(define reported '())
(let ()
  ;; The reporter must be installed BEFORE start-server: connection threads
  ;; inherit the parameterization of the server's accept loop.
  (define-values (p2 stop2)
    (parameterize ([current-glaze-error-reporter
                    (lambda (exn uri) (set! reported (list (exn-message exn) uri)))])
      (start-server #:port 18996 #:public-dir "/tmp"
                    #:api (list (GET "api/boom"
                                     (lambda (req) (raise-user-error 'kaboom "x")))))))
  (let*-values ([(_s6 _h6 _b6) (call "/api/boom" #:port 18996)])
    (check-true (string-contains? _s6 "500") "boom still answers 500"))
  (check-equal? (second reported) "api/boom" "reporter sees the URI")
  (check-true (string-contains? (first reported) "kaboom") "reporter sees the exn")
  (stop2))

(shutdown)

;; ---- update checking ----
(check-true (newer-version? "1.10.0" "1.9.2") "numeric not lexicographic")
(check-false (newer-version? "1.0.0" "1.0.0") "equal is not newer")
(check-true (newer-version? "2.0" "1.9.9") "shorter version pads with zeros")
(check-false (newer-version? "1.2" "1.2.1") "older is not newer")

(define dir (make-temporary-file "upd-~a" 'directory))
(call-with-output-file (build-path dir "manifest.json")
  (lambda (o)
    (write-bytes #"{\"version\":\"9.9.9\",\"url\":\"https://x/9.9.9\",\"notes\":\"big\"}" o))
  #:exists 'replace)
(define-values (p3 stop3) (start-server #:port 18997 #:public-dir dir))
(define info (check-update "http://127.0.0.1:18997/manifest.json"
                           #:current-version "1.0.0"))
(check-equal? (hash-ref info 'version) "9.9.9" "manifest parsed")
(check-equal? (hash-ref info 'url) "https://x/9.9.9")
(check-false (check-update "http://127.0.0.1:18997/manifest.json"
                           #:current-version "9.9.9")
             "same version -> #f")
(check-false (check-update "http://127.0.0.1:18997/none.json")
             "missing manifest -> #f")
(stop3)
(delete-directory/files dir)

;; ---- run-app plumbing: token parameter + events pass-through ----
(check-true (procedure? run-app))
(check-equal? (current-api-token) "" "parameter default is empty")
