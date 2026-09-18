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
(define bootstrap (make-api-token))
(check-true (regexp-match? #px"^[0-9a-f]{32}$" token) "token is 32 hex chars")
(check-false (string=? (make-api-token) token) "tokens are random")

(define-values (port shutdown)
  (start-server #:port 18995
                #:public-dir "/tmp"
                #:api (list (GET "api/ping" (lambda (req) (hasheq 'pong #t))))
                #:api-token token
                #:bootstrap-token bootstrap))

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
;; api.js is openly readable, so it must not mint credentials — no cookie,
;; no token anywhere in it
(let*-values ([(_s4 h4 b4) (call "/glaze/api.js")])
  (check-false
   (for/or ([hh (in-list h4)])
     (string-prefix? (string-downcase (bytes->string/latin-1 hh)) "set-cookie:"))
   "api.js sets no cookie")
  (check-false (string-contains? (bytes->string/utf-8 b4) token)
               "api.js body does not contain the token"))

;; one-time bootstrap: a short-lived nonce distinct from the API token is
;; exchanged for an HttpOnly API-token cookie and then consumed.
(let*-values ([(_s5 h5 _b5) (call (format "/?glaze-token=~a" bootstrap))])
  (check-true (string-contains? _s5 "302") "bootstrap redirects")
  (check-true
   (for/or ([hh (in-list h5)])
     (string-contains? (string-downcase (bytes->string/latin-1 hh))
                       (format "glaze_token=~a" token)))
   "bootstrap sets API token cookie, not bootstrap nonce")
  (check-false
   (for/or ([hh (in-list h5)])
     (string-contains? (bytes->string/latin-1 hh)
                       (format "glaze_token=~a" bootstrap)))
   "bootstrap nonce is never stored as the capability cookie")
  (check-true
   (for/or ([hh (in-list h5)])
     (define s (string-downcase (bytes->string/latin-1 hh)))
     (and (string-prefix? s "set-cookie:")
          (string-contains? s "httponly")))
   "bootstrap cookie is HttpOnly")
  ;; cookie channel: replay the minted cookie as a Cookie header
  (let*-values ([(_s6 _h6 _b6) (call "/api/ping"
                         #:headers (list (format "Cookie: glaze_token=~a" token)))])
    (check-true (string-contains? _s6 "200") "cookie token -> 200")))

;; Bootstrap nonce is consumed: replaying it cannot mint another cookie.
(let*-values ([(_sr hr _br) (call (format "/?glaze-token=~a" bootstrap))])
  (check-false
   (for/or ([hh (in-list hr)])
     (string-prefix? (string-downcase (bytes->string/latin-1 hh)) "set-cookie:"))
   "bootstrap nonce cannot be replayed"))

;; Browser-origin capability requests are pinned to this exact local port.
(let*-values ([(_so _ho _bo)
               (call "/api/ping"
                     #:headers
                     (list (format "X-Glaze-Token: ~a" token)
                           "Origin: http://127.0.0.1:19999"))])
  (check-true (string-contains? _so "403") "foreign localhost origin -> 403"))
(let*-values ([(_ss _hs _bs)
               (call "/api/ping"
                     #:headers
                     (list (format "X-Glaze-Token: ~a" token)
                           "Origin: http://127.0.0.1:18995"))])
  (check-true (string-contains? _ss "200") "same-origin API request -> 200"))

;; wrong token in the query never mints anything
(let*-values ([(_s7 h7 _b7) (call "/?glaze-token=wrong")])
  (check-false
   (for/or ([hh (in-list h7)])
     (string-prefix? (string-downcase (bytes->string/latin-1 hh)) "set-cookie:"))
   "wrong bootstrap token mints nothing"))

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
    (check-true (string-contains? _s6 "500") "boom still answers 500")
    (check-false (string-contains? (bytes->string/utf-8 _b6) "kaboom")
                 "500 response does not leak handler exception text")
    (check-true (string-contains? (bytes->string/utf-8 _b6) "internal server error")
                "500 response uses generic client message"))
  (check-equal? (second reported) "api/boom" "reporter sees the URI")
  (check-true (string-contains? (first reported) "kaboom") "reporter sees the exn")
  (stop2))

;; An events-only server must still enforce the capability token even when it
;; has zero API routes (regression for a previous `(pair? api-routes)` guard).
(define sse-bus (make-event-bus))
(define-values (_sse-port stop-sse)
  (start-server #:port 18998
                #:public-dir "/tmp"
                #:events sse-bus
                #:api-token token))
(let*-values ([(_se _he _be) (call "/glaze/events" #:port 18998)])
  (check-true (string-contains? _se "401") "SSE-only server requires token"))
(stop-sse)

(shutdown)

;; ---- update checking ----
(check-true (newer-version? "1.10.0" "1.9.2") "numeric not lexicographic")
(check-false (newer-version? "1.0.0" "1.0.0") "equal is not newer")
(check-true (newer-version? "2.0" "1.9.9") "shorter version pads with zeros")
(check-false (newer-version? "1.2" "1.2.1") "older is not newer")

;; SHA verification accepts both path and string path inputs and rejects an
;; invalid digest shape before invoking openssl.
(define hash-file (make-temporary-file "glaze-sha-test-~a"))
(call-with-output-file hash-file
  (lambda (o) (display "abc" o))
  #:exists 'replace)
(when (find-executable-path "openssl" #f)
  (check-true
   (verify-file-sha256
    (path->string hash-file)
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
   "sha256 verifier accepts string paths"))
(check-false (verify-file-sha256 hash-file "not-a-digest")
             "sha256 verifier rejects malformed digest")
(delete-file hash-file)

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
