#lang racket/base

;; Commercial-polish suite: SSE event bus, Host-header guard, generated JS
;; client, and the define-api-routes macro (Racket proc + route + 400/500).

(require rackunit
         racket/list
         racket/file
         racket/port
         racket/string
         json
         net/http-client
         glaze/server
         glaze/api
         glaze/api-macros
         glaze/events)

;; ---- event bus unit ----
(define bus (make-event-bus))
(check-true (event-bus? bus) "make-event-bus")
(define ch (bus-subscribe! bus))
(bus-broadcast! bus 'tick (hasheq 'n 1))
;; delivery shape: (list seq name data) — the seq drives the SSE id: line
(define-values (seq1 name1 data1)
  (let ([evt (bus-wait ch 2)]) (values (first evt) (second evt) (third evt))))
(check-equal? name1 'tick "bus delivers the event name")
(check-equal? data1 #hasheq((n . 1)) "bus delivers payload")
(check-true (exact-positive-integer? seq1) "events carry a sequence number")
(bus-unsubscribe! bus ch)
(bus-broadcast! bus 'tick (hasheq 'n 2))
(check-equal? (bus-wait ch 0.2) 'timeout "unsubscribed channel gets nothing")

;; ---- macro + routes + guards, over HTTP ----
(define count (box 0))
(define (bump! d)
  (set-box! count (+ (unbox count) d)))

(define-api-routes api
                   [(POST "api/counter/bump")
                    (bump* [delta exact-nonnegative-integer? 1])
                    (begin
                      (bump! delta)
                      (hasheq 'count (unbox count)))]
                   [(GET "api/items/:id") (item id) (hasheq 'id id)]
                   [(GET "api/boom") (boom) (raise-user-error 'boom "nope")])

;; The macro also defines a plain Racket procedure.
(check-equal? (begin
                (bump* 10)
                (unbox count))
              10
              "macro defines plain proc")

(define dir (make-temporary-file "events-t-~a" 'directory))
(current-glaze-error-reporter (lambda (_exn _uri) (void)))
(define-values (port shutdown) (start-server #:port 18990 #:public-dir dir #:api api #:events bus))

(define (call method path [data #f] #:host [host #f])
  (define-values (st _h in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port port
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers (append '("Content-Type: application/json")
                                     (if host
                                         (list (format "Host: ~a" host))
                                         '()))))
  (define b (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 st) b))

;; default when body absent
(let-values ([(st b) (call "POST" "/api/counter/bump")])
  (check-true (string-contains? st "200"))
  (check-equal? (hash-ref (bytes->jsexpr b) 'count) 11))
;; explicit body
(let-values ([(st b) (call "POST" "/api/counter/bump" #"{\"delta\":5}")])
  (check-equal? (hash-ref (bytes->jsexpr b) 'count) 16))
;; bad type -> 400 naming the parameter
(let-values ([(st b) (call "POST" "/api/counter/bump" #"{\"delta\":\"x\"}")])
  (check-true (string-contains? st "400"))
  (check-true (string-contains? (bytes->string/utf-8 b) "delta")))
;; path param
(let-values ([(_st b) (call "GET" "/api/items/xyz")])
  (check-equal? (hash-ref (bytes->jsexpr b) 'id) "xyz"))
;; handler error -> 500
(let-values ([(st _) (call "GET" "/api/boom")])
  (check-true (string-contains? st "500")))
;; DNS-rebinding guard
(let-values ([(st _) (call "GET" "/" #:host "evil.example.com")])
  (check-true (string-contains? st "403") "hostile Host -> 403"))
;; normal host passes (a path that serves 200 without an index.html)
(let-values ([(st _) (call "GET" "/glaze/api.js" #:host (format "localhost:~a" port))])
  (check-true (string-contains? st "200") "localhost Host passes"))

;; ---- generated JS client ----
(let-values ([(_st b) (call "GET" "/glaze/api.js")])
  (define js (bytes->string/utf-8 b))
  (check-true (string-contains? js "glaze.call") "client has call wrapper")
  (check-true (string-contains? js "counterBump: function(body)") "route -> counterBump()")
  (check-true (string-contains? js "itemsId:") "path param -> itemsId()")
  (check-true (string-contains? js "EventSource('/glaze/events')") "SSE endpoint"))

;; ---- SSE over HTTP ----
;; Use Racket's HTTP client so the test has no external `curl` dependency.
;; Synchronize on the event-bus subscription instead of racing a fixed sleep.
(define sse-result (make-channel))
(define sse-reader
  (thread (lambda ()
            (with-handlers ([exn:fail? (lambda (e) (channel-put sse-result e))])
              (define-values (_st _headers in)
                (http-sendrecv "127.0.0.1" "/glaze/events" #:port port #:ssl? #f #:method "GET"))
              (define (next-meaningful-line)
                ;; frames carry an id: <seq> line (GLZ1 event sequence);
                ;; skip it the way a generic SSE consumer would
                (let skip ()
                  (define line (read-line in 'any))
                  (if (and (string? line) (string-prefix? line "id: "))
                      (skip)
                      line)))
              (define event-line (next-meaningful-line))
              (define data-line (next-meaningful-line))
              (close-input-port in)
              (channel-put sse-result (format "~a\n~a\n" event-line data-line))))))
(define subscribed?
  (let ([deadline (+ (current-inexact-milliseconds) 5000)])
    (let loop ()
      (cond
        [(positive? (bus-subscriber-count bus)) #t]
        [(>= (current-inexact-milliseconds) deadline) #f]
        [else
         (sleep 0.01)
         (loop)]))))
(check-true subscribed? "SSE client subscribed")
(when subscribed?
  (bus-broadcast! bus 'hello (hasheq 'msg "world")))
(define sse-value (sync/timeout 5 sse-result))
(check-false (exn:fail? sse-value) "SSE reader completed without an exception")
(define sse-text (if (string? sse-value) sse-value ""))
(unless sse-value
  (kill-thread sse-reader))
(shutdown)
(check-true (string-contains? sse-text "event: hello") "SSE event name delivered")
(check-true (string-contains? sse-text "\"msg\":\"world\"") "SSE payload delivered")

(delete-directory/files dir)
