#lang racket/base

;; Security hardening suite: static-file containment (path traversal,
;; symlink escape), the cross-site request guard (Origin / Sec-Fetch-Site),
;; request body limits, sanitized 500 bodies, generated-client name
;; validation, event-bus overflow accounting, and run-app lifecycle
;; exception safety (on-ready failure cleanup, on-close failure survival).

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/string
         racket/tcp
         json
         net/http-client
         glaze/server
         glaze/api
         glaze/events
         glaze/app
         glaze/webview/main)

;; ---- helpers ----

(define (http-call port path
                   #:method [method "GET"]
                   #:data [data #f]
                   #:headers [headers '()])
  (define-values (st h in)
    (http-sendrecv "127.0.0.1" path
                   #:port port #:ssl? #f
                   #:method method
                   #:data data
                   #:headers headers))
  (define b (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 st) b))

(define (port-alive? port)
  (with-handlers ([exn:fail:network? (lambda (_) #f)])
    (define-values (in out) (tcp-connect "127.0.0.1" port))
    (close-input-port in)
    (close-output-port out)
    #t))

(define fixture-dir (make-temporary-file "glaze-sec-~a" 'directory))
(define public-dir (build-path fixture-dir "public"))
(make-directory* public-dir)
(call-with-output-file (build-path public-dir "index.html")
                       (lambda (o) (display "<h1>spa</h1>" o))
                       #:exists 'replace)
(make-directory* (build-path public-dir "assets"))
(call-with-output-file (build-path public-dir "assets" "app.js")
                       (lambda (o) (display "console.log(1)" o))
                       #:exists 'replace)
;; The treasure the traversal must never reach.
(call-with-output-file (build-path fixture-dir "secret.txt")
                       (lambda (o) (display "TOPSECRET" o))
                       #:exists 'replace)

;; ---- static-file containment ----

(define-values (sec-port sec-shutdown)
  (start-server #:port 18930 #:public-dir public-dir))

;; percent-encoded ".." must serve the SPA fallback, never the outside file
(let-values ([(st body) (http-call sec-port "/%2e%2e/secret.txt")])
  (check-true (string-contains? st "200") "encoded traversal answers (fallback)")
  (check-false (string-contains? (bytes->string/utf-8 body) "TOPSECRET")
               "encoded traversal does not leak the outside file"))

;; mixed traversal segments
(let-values ([(st body) (http-call sec-port "/assets/%2e%2e/%2e%2e/secret.txt")])
  (check-false (string-contains? (bytes->string/utf-8 body) "TOPSECRET")
               "nested encoded traversal does not leak"))

;; a raw ".." in the request line must not kill the connection thread
(let-values ([(st _body) (http-call sec-port "/../secret.txt")])
  (check-true (string-contains? st "404") "raw dotdot -> 404"))
(check-true (port-alive? sec-port) "connection thread survived a raw dotdot request")

;; the server still serves normally afterwards
(let-values ([(st body) (http-call sec-port "/assets/app.js")])
  (check-true (string-contains? st "200") "static serving still works after traversal attempts")
  (check-true (string-contains? (bytes->string/utf-8 body) "console.log")))

;; symlink inside public-dir pointing outside is not followed
(unless (eq? (system-type 'os) 'windows)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (make-file-or-directory-link (build-path public-dir "leak") (build-path fixture-dir "secret.txt"))
    (let-values ([(_st body) (http-call sec-port "/leak")])
      (check-false (string-contains? (bytes->string/utf-8 body) "TOPSECRET")
                   "symlink escape does not leak"))))

(sec-shutdown)

;; ---- cross-site request guard ----

(define-values (cs-port cs-shutdown)
  (start-server #:port 18933
                #:public-dir public-dir
                #:api (list (POST "api/touch" (lambda (req) (hasheq 'ok #t)))
                            (GET "api/touch" (lambda (req) (hasheq 'ok #t))))))

;; foreign Origin on the API bridge -> 403
(let-values ([(st _b) (http-call cs-port "/api/touch"
                                 #:method "POST"
                                 #:data "{}"
                                 #:headers '("Origin: https://evil.example"))])
  (check-true (string-contains? st "403") "foreign Origin on API -> 403"))
;; same-origin loopback spellings pass
(let-values ([(st _b) (http-call cs-port "/api/touch"
                                 #:method "POST"
                                 #:data "{}"
                                 #:headers (list (format "Origin: http://127.0.0.1:~a" cs-port)))])
  (check-true (string-contains? st "200") "same-origin Origin (127.0.0.1) -> 200"))
(let-values ([(st _b) (http-call cs-port "/api/touch"
                                 #:method "POST"
                                 #:data "{}"
                                 #:headers (list (format "Origin: http://localhost:~a" cs-port)))])
  (check-true (string-contains? st "200") "same-origin Origin (localhost) -> 200"))
;; right host, wrong port -> 403
(let-values ([(st _b) (http-call cs-port "/api/touch"
                                 #:method "POST"
                                 #:data "{}"
                                 #:headers '("Origin: http://127.0.0.1:1"))])
  (check-true (string-contains? st "403") "Origin port mismatch -> 403"))
;; Sec-Fetch-Site without Origin (older GET flows)
(let-values ([(st _b) (http-call cs-port "/api/touch"
                                 #:headers '("Sec-Fetch-Site: cross-site"))])
  (check-true (string-contains? st "403") "Sec-Fetch-Site cross-site -> 403"))
(let-values ([(st _b) (http-call cs-port "/api/touch"
                                 #:headers '("Sec-Fetch-Site: same-origin"))])
  (check-true (string-contains? st "200") "Sec-Fetch-Site same-origin -> 200"))
;; neither header (curl / programmatic clients) is unaffected
(let-values ([(st _b) (http-call cs-port "/api/touch" #:method "POST" #:data "{}")])
  (check-true (string-contains? st "200") "no Origin/Sec-Fetch headers -> 200"))
;; the guard covers the event stream bridge too; static files stay open
(let-values ([(st _b) (http-call cs-port "/index.html"
                                 #:headers '("Origin: https://evil.example"))])
  (check-true (string-contains? st "200") "static files are not Origin-gated"))

(cs-shutdown)

;; ---- request body limit ----

(define-values (bl2-port bl2-shutdown)
  (start-server #:port 18934
                #:public-dir public-dir
                #:api (list (POST "api/upload" (lambda (req) (hasheq 'ok #t))))
                #:max-body-size 100))
(let-values ([(st _b) (http-call bl2-port "/api/upload"
                                 #:method "POST"
                                 #:data (make-string 200 #\x)
                                 #:headers '("Content-Type: application/json"))])
  (check-true (string-contains? st "413") "oversized body -> 413"))
(let-values ([(st _b) (http-call bl2-port "/api/upload"
                                 #:method "POST"
                                 #:data "{\"x\":1}"
                                 #:headers '("Content-Type: application/json"))])
  (check-true (string-contains? st "200") "body within limit -> 200"))
(bl2-shutdown)

;; ---- 500 bodies never echo internal exception text ----

(define reported-500 (box #f))
(define-values (e500-port e500-shutdown)
  (parameterize ([current-glaze-error-reporter
                  (lambda (exn uri) (set-box! reported-500 (list (exn-message exn) uri)))])
    (start-server #:port 18935
                  #:public-dir public-dir
                  #:api (list (GET "api/boom"
                                   (lambda (req)
                                     (error 'internal "DB PASSWORD hunter2 at /secret/db")))))))
(let-values ([(st body) (http-call e500-port "/api/boom")])
  (check-true (string-contains? st "500") "handler raise -> 500")
  (check-true (hash? (bytes->jsexpr body)) "500 body is JSON")
  (check-false (string-contains? (bytes->string/utf-8 body) "hunter2")
               "500 body hides the exception message")
  (check-false (string-contains? (bytes->string/utf-8 body) "/secret/db")
               "500 body hides paths")
  (check-true (string-contains? (first (unbox reported-500)) "hunter2")
              "the reporter still sees the full exception"))
(e500-shutdown)

;; ---- generated-client name validation ----

;; two routes that camel-case to the same JS name fail at startup
(check-exn exn:fail?
           (lambda ()
             (start-server #:port 0
                           #:public-dir public-dir
                           #:api (list (GET "api/user-get" (lambda (req) (hasheq)))
                                       (GET "api/user/get" (lambda (req) (hasheq)))))))
;; a route whose name sanitizes to nothing fails at startup
(check-exn exn:fail?
           (lambda ()
             (start-server #:port 0
                           #:public-dir public-dir
                           #:api (list (GET "api/---" (lambda (req) (hasheq)))))))
;; digit-leading and dotted segments are sanitized into valid identifiers
(define-values (jsn-port jsn-shutdown)
  (start-server #:port 18936
                #:public-dir public-dir
                #:api (list (GET "api/3d-view" (lambda (req) (hasheq)))
                            (GET "api/foo.bar" (lambda (req) (hasheq))))))
(let-values ([(_st body) (http-call jsn-port "/glaze/api.js")])
  (define js (bytes->string/utf-8 body))
  (check-true (string-contains? js "_3dView:") "digit-leading name is prefixed")
  (check-true (string-contains? js "foobar:") "dotted segment is sanitized"))
(jsn-shutdown)

;; ---- event-bus overflow is drop-oldest, counted, and reported ----

(define drop-reports '())
(parameterize ([current-event-drop-reporter
                (lambda (dropped name) (set! drop-reports (cons name drop-reports)))])
  (define bus (make-event-bus))
  (define ch (bus-subscribe! bus))
  (for ([i (in-range 256)])
    (bus-broadcast! bus 'tick (hasheq 'i i)))
  (check-equal? (bus-dropped-count bus) 0 "full backlog without overflow drops nothing")
  (for ([i (in-range 256 300)])
    (bus-broadcast! bus 'tick (hasheq 'i i)))
  (check-equal? (bus-dropped-count bus) 44 "overflow drops exactly the surplus")
  (check-true (>= (length drop-reports) 1) "overflow was reported")
  ;; oldest events made room for the newest: the queue starts at event 44
  (check-equal? (bus-wait ch 2) '(tick #hasheq((i . 44))) "oldest events were dropped first")
  (check-equal? (bus-wait ch 2) '(tick #hasheq((i . 45))) "queue stays ordered after overflow"))

;; ---- run-app lifecycle exception safety (real native window) ----

;; #:on-ready raising tears down window AND server, then propagates.
(unless (webview-supported?)
  (printf "glaze-test/security: skipping run-app lifecycle e2e — no native webview\n"))
(when (webview-supported?)
  (define app-dir public-dir)
  (check-exn exn:fail?
             (lambda ()
               (run-app #:public-dir app-dir
                        #:port 18937
                        #:title "glaze security test"
                        #:on-ready (lambda (wv url) (error 'test "ready failure"))))
             "on-ready failure propagates")
  (sleep 0.3)
  (check-false (port-alive? 18937) "on-ready failure stopped the server")

  ;; a raising #:on-close hook must not wedge run-app: it reports and the
  ;; app still closes, returning normally.
  (define close-errors (box '()))
  (define app-result (make-channel))
  (define app-thread
    (thread
     (lambda ()
       (define-values (kind _shutdown)
         (run-app #:public-dir app-dir
                  #:port 18938
                  #:title "glaze security test"
                  #:on-close (lambda () (error 'test "close failure"))
                  #:on-error (lambda (exn uri)
                               (set-box! close-errors (cons (exn-message exn) (unbox close-errors))))))
       (channel-put app-result kind))))
  ;; wait for the server, then close the window the way the OS would
  (let loop ([deadline (+ (current-inexact-milliseconds) 15000)])
    (cond
      [(port-alive? 18938) (void)]
      [(> (current-inexact-milliseconds) deadline) (fail "run-app server never came up")]
      [else (sleep 0.05) (loop deadline)]))
  ;; target the window by its port so a window from an earlier e2e that is
  ;; still tearing down cannot be closed by mistake
  (define target-wv
    (let loop ([deadline (+ (current-inexact-milliseconds) 15000)])
      (define match
        (findf (lambda (wv)
                 (define u (webview-url wv))
                 (and u (string-contains? u ":18938")))
               (all-webviews)))
      (cond
        [match match]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else (sleep 0.05) (loop deadline)])))
  (check-not-false target-wv "run-app opened its window")
  (when target-wv
    (webview-close target-wv))
  (define kind (sync/timeout 30 app-result))
  (check-equal? kind 'webview "run-app survived a raising on-close hook")
  (check-true (for/or ([m (in-list (unbox close-errors))])
                 (string-contains? m "close failure"))
              "on-close failure was reported")
  (kill-thread app-thread))

(delete-directory/files fixture-dir)
