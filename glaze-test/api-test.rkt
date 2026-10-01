#lang racket/base

;; JSON API route tests: HTTP round trips through start-server's #:api —
;; method matching, :param capture, JSON body parsing (jsexpr uses SYMBOL
;; keys), error wrapping, static fallback, and run-app being composed from
;; the same pieces.

(require rackunit
         racket/async-channel
         racket/file
         racket/string
         racket/tcp
         racket/port
         json
         net/http-client
         web-server/http/response-structs
         glaze/server
         glaze/api)

(define dir (make-temporary-file "glaze-api-~a" 'directory))
(call-with-output-file (build-path dir "index.html")
                       (lambda (o) (display #"<html>idx</html>" o))
                       #:exists 'replace)

(define count (box 0))
(define reported-api-error (box #f))
(current-glaze-error-reporter (lambda (exn uri) (set-box! reported-api-error (cons exn uri))))

(define-values (port shutdown)
  (start-server #:port 18960
                #:public-dir dir
                #:api
                (list (GET "api/ping" (lambda (req) (hasheq 'pong #t)))
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
    (http-sendrecv "127.0.0.1"
                   path
                   #:port 18960
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers (if data
                                 '("Content-Type: application/json")
                                 '())))
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
(check-pred pair? (unbox reported-api-error) "handler error is reported")
(when (pair? (unbox reported-api-error))
  (check-true (exn:fail? (car (unbox reported-api-error)))))

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

;; ---- streaming responses (chunked + SSE) ----

;; Drain `in` on a side thread, chunk by chunk (read-bytes-avail! returns as
;; soon as ANY byte lands, so incrementality is observable), until eof or
;; timeout. Returns the accumulated bytes.
(define (drain-thread in)
  (define ch (make-async-channel))
  (define buf (make-bytes 256))
  (define t
    (thread (lambda ()
              (let loop ()
                (define n (read-bytes-avail! buf in))
                (cond
                  [(eof-object? n) (async-channel-put ch 'eof)]
                  [else
                   (async-channel-put ch (subbytes buf 0 n))
                   (loop)])))))
  (values ch t))

(define sdir (make-temporary-file "glaze-stream-~a" 'directory))
(call-with-output-file (build-path sdir "index.html")
                       (lambda (o) (display #"<html>idx</html>" o))
                       #:exists 'replace)

(define unblock (make-semaphore))

(define-values (_sport sdown)
  (start-server
   #:port 18961
   #:public-dir sdir
   #:api (list (GET "api/stream"
                    (lambda (req)
                      (streaming-response (lambda (out)
                                            (display "one" out)
                                            (flush-output out)
                                            ;; The test releases this only after it has seen "one"
                                            ;; on the wire, so end-buffering would fail the test.
                                            (semaphore-wait unblock)
                                            (display "two" out)
                                            (flush-output out))
                                          #:mime #"text/plain")))
               (GET "api/sse"
                    (lambda (req)
                      (event-stream-response (lambda (send)
                                               (send 'delta (hasheq 'text "hel"))
                                               (send 'delta (hasheq 'text "lo"))
                                               (send 'done (hasheq 'ok #t)))))))))

;; Unit level: constructors produce response? values, reject junk.
(check-true (response? (streaming-response (lambda (out) (void)))) "streaming-response -> response?")
(check-true (response? (event-stream-response (lambda (send) (void))))
            "event-stream-response -> response?")
(check-exn exn:fail:contract?
           (lambda () (streaming-response 42))
           "streaming-response rejects non-procedure")
(check-exn exn:fail:contract?
           (lambda () (event-stream-response 42))
           "event-stream-response rejects non-procedure")

;; Wire level, chunked: "one" must arrive while the writer is still blocked.
(define-values (sin sout) (tcp-connect "127.0.0.1" 18961))
(fprintf sout "GET /api/stream HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
(flush-output sout)
(define-values (stream-ch stream-reader) (drain-thread sin))
(define seen-one?
  (let loop ([acc #""])
    (cond
      [(regexp-match? #rx"one" acc) #t]
      [else
       (define c (sync/timeout 5 stream-ch))
       (cond
         [(or (not c) (eq? c 'eof)) #f]
         [else (loop (bytes-append acc c))])])))
(check-true seen-one? "first chunk delivered before writer finishes")

(semaphore-post unblock)
(define stream-rest
  (let loop ([acc #""]
             [eof? #f])
    (cond
      [eof? acc]
      [else
       (define c (sync/timeout 5 stream-ch))
       (cond
         [(not c) (bytes-append acc #"!!timeout")]
         [(eq? c 'eof) (loop acc #t)]
         [else (loop (bytes-append acc c) #f)])])))
(check-true (regexp-match? #rx"two" stream-rest) "second chunk delivered after unblock")
(close-input-port sin)
(close-output-port sout)

;; Wire level, SSE: frames well-formed, headers right, connection closes.
(define-values (sin2 sout2) (tcp-connect "127.0.0.1" 18961))
(fprintf sout2 "GET /api/sse HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
(flush-output sout2)
(define-values (sse-ch sse-reader) (drain-thread sin2))
(define sse-raw
  (let loop ([acc #""])
    (define c (sync/timeout 5 sse-ch))
    (cond
      [(not c) (bytes-append acc #"!!timeout")]
      [(eq? c 'eof) acc]
      [else (loop (bytes-append acc c))])))
(check-true (regexp-match? #rx#"200" sse-raw) "SSE route matched")
(check-true (regexp-match? #rx#"text/event-stream" sse-raw) "SSE content type")
(check-true (regexp-match? #rx#"Cache-Control: no-cache" sse-raw) "SSE no-cache header")
(check-true
 (regexp-match?
  #px"event: delta\ndata: \\{\"text\":\"hel\"\\}\n\nevent: delta\ndata: \\{\"text\":\"lo\"\\}\n\nevent: done\ndata: \\{\"ok\":true\\}\n\n$"
  sse-raw)
 "SSE frames well-formed and stream ends when sender returns")
(close-input-port sin2)
(close-output-port sout2)
(kill-thread stream-reader)
(kill-thread sse-reader)

(sdown)
(delete-directory/files sdir)
