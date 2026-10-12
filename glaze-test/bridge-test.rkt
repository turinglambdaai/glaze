#lang racket/base

;; GLZ1 bridge suite: hello manifest, invoke envelopes (typed errors,
;; request ids, timeout), cancellation, event sequence numbers on SSE, and
;; the app lifecycle state machine (multi-window + tray-resident quit
;; policy, real native windows).

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/string
         json
         net/http-client
         glaze/bridge
         glaze/server
         glaze/api
         glaze/api-macros
         glaze/events
         glaze/app
         glaze/webview/main)

(define (call method path [data #f] #:port [port 18991] #:headers [headers '()])
  (define-values (st h in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port port
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers (append '("Content-Type: application/json") headers)))
  (define b (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 st) b))

;; ---- protocol unit: envelope parsing + error taxonomy ----

(check-true (bridge-error-code? 'unknown-command) "closed taxonomy accepts known codes")
(check-false (bridge-error-code? 'no-such-code) "closed taxonomy rejects unknown codes")
(check-exn exn:fail:glaze:bridge?
           (lambda () (raise-bridge-error 'bad-envelope "test" #f))
           "raise-bridge-error raises the bridge exn")
(check-equal? (exn:fail:glaze:bridge-code (with-handlers ([exn:fail:glaze:bridge? values])
                                            (raise-bridge-error 'timed-out "late" (hasheq 'ms 5))))
              'timed-out
              "bridge exn carries the code")
(check-equal? (exn:fail:glaze:bridge-data (with-handlers ([exn:fail:glaze:bridge? values])
                                            (raise-bridge-error 'timed-out "late" (hasheq 'ms 5))))
              (hasheq 'ms 5)
              "bridge exn carries structured data")

;; bus delivery shape: (list seq name data) with increasing seq
(define shape-bus (make-event-bus))
(define shape-ch (bus-subscribe! shape-bus))
(bus-broadcast! shape-bus 'probe (hasheq 'n 0))
(define shape-evt (bus-wait shape-ch 2))
(check-true (and (list? shape-evt) (= (length shape-evt) 3)) "payload is (list seq name data)")
(check-true (exact-positive-integer? (first shape-evt)) "seq is a positive integer")
(check-equal? (second shape-evt) 'probe)

;; ---- HTTP bridge ----

(define-api-routes api
                   [(GET "api/ping") (ping) (hasheq 'pong #t)]
                   [(GET "api/items/:id") (item id) (hasheq 'id id)]
                   [(POST "api/items") (create [name string?]) (hasheq 'created name)]
                   [(GET "api/slow")
                    (slow)
                    ;; cooperative: finishes early when cancelled
                    (set-box! slow-handler-thread (current-thread))
                    (let loop ([n 0])
                      (cond
                        [(bridge-cancelled?) "cancelled"]
                        [(>= n 50) "done"]
                        [else
                         (sleep 0.02)
                         (loop (add1 n))]))]
                   [(GET "api/cancel-aware")
                    (cancel-aware)
                    (let loop ()
                      (if (bridge-cancelled?)
                          (raise-bridge-error 'cancelled "request cancelled")
                          (begin
                            (sleep 0.02)
                            (loop))))]
                   [(GET "api/boom") (boom) (error 'internal "SECRET-DB-PATH")])

(define slow-handler-thread (box #f))

;; Keel command names must remain unique when Glaze overloads one generated
;; client name with several HTTP methods.
(define-api-routes overloaded-api
                   [(GET "api/items") (items-get) 'get]
                   [(POST "api/items") (items-post) 'post])
(define overloaded-schema (hash-ref (build-hello overloaded-api) 'schema))
(check-equal? (for/list ([command (in-list (hash-ref overloaded-schema 'commands))])
                (hash-ref command 'name))
              '("api-items-get" "api-items-post")
              "overloaded routes receive stable unique keel command names")

(define dir (make-temporary-file "glz1-t-~a" 'directory))
(define bus (make-event-bus))
(current-glaze-error-reporter (lambda (_exn _uri) (void)))
(define-values (port shutdown) (start-server #:port 18991 #:public-dir dir #:api api #:events bus))

;; hello: version + route manifest + keel schema rendering
(let-values ([(_st b) (call "GET" "/glaze/hello")])
  (define hello (bytes->jsexpr b))
  (check-equal? (hash-ref hello 'glz) glz1-version "hello speaks the protocol version")
  (check-equal? (hash-ref hello 'name) "glaze")
  (check-true (list? (hash-ref hello 'routes)) "hello lists routes")
  (check-true (for/or ([r (in-list (hash-ref hello 'routes))])
                (and (equal? (hash-ref r 'path) "/api/items/:id")
                     (equal? (hash-ref r 'method) "GET")))
              "manifest includes param routes")
  ;; the same surface as a transport-neutral keel schema (jsexpr: symbol
  ;; keys; values stay strings)
  (define schema (hash-ref hello 'schema))
  (check-equal? (hash-ref schema 'id) "glaze-routes")
  (check-equal? (hash-ref schema 'contract) 1)
  (check-true (list? (hash-ref schema 'commands)) "schema lists commands")
  (check-true (for/or ([c (in-list (hash-ref schema 'commands))])
                (and (equal? (hash-ref c 'name) "ping")
                     (equal? (hash-ref (hash-ref c 'result) 'name) "Value")
                     (and (member "timed-out" (hash-ref c 'errors)) #t)))
              "commands carry keel result type and error codes"))

;; invoke: happy path with envelope shape
(let-values ([(_st b)
              (call "POST" "/glaze/invoke" "{\"glz\":1,\"id\":\"r1\",\"path\":\"api/ping\"}")])
  (define out (bytes->jsexpr b))
  (check-equal? (hash-ref out 'glz) 1)
  (check-equal? (hash-ref out 'id) "r1")
  (check-true (hash-ref out 'ok))
  (check-equal? (hash-ref out 'outcome) "succeeded" "keel terminal outcome")
  (check-equal? (hash-ref (hash-ref out 'value) 'pong) #t))

;; invoke: path params from the envelope path
(let-values ([(_st b)
              (call "POST" "/glaze/invoke" "{\"glz\":1,\"id\":\"r2\",\"path\":\"api/items/42\"}")])
  (define out (bytes->jsexpr b))
  (check-true (hash-ref out 'ok))
  (check-equal? (hash-ref (hash-ref out 'value) 'id) "42"))

;; invoke: args become the handler's JSON body
(let-values ([(_st b)
              (call "POST"
                    "/glaze/invoke"
                    "{\"glz\":1,\"id\":\"r3\",\"path\":\"api/items\",\"args\":{\"name\":\"tok\"}}")])
  (define out (bytes->jsexpr b))
  (check-true (hash-ref out 'ok))
  (check-equal? (hash-ref (hash-ref out 'value) 'created) "tok"))

;; invoke: unknown command -> typed error with a failed terminal
(let-values ([(_st b)
              (call "POST" "/glaze/invoke" "{\"glz\":1,\"id\":\"r4\",\"path\":\"api/nothing\"}")])
  (define out (bytes->jsexpr b))
  (check-false (hash-ref out 'ok))
  (check-equal? (hash-ref out 'outcome) "failed" "typed errors are failed terminals")
  (check-equal? (hash-ref (hash-ref out 'error) 'code) "unknown-command"))

;; invoke: explicit method mismatch -> method-not-allowed (no silent GET
;; fallback when the caller asked for a specific method)
(let-values ([(_st b)
              (call "POST"
                    "/glaze/invoke"
                    "{\"glz\":1,\"id\":\"r5\",\"path\":\"api/items\",\"method\":\"DELETE\"}")])
  (check-equal? (hash-ref (hash-ref (bytes->jsexpr b) 'error) 'code) "method-not-allowed"))

;; invoke: bad envelope version
(let-values ([(_st b)
              (call "POST" "/glaze/invoke" "{\"glz\":99,\"id\":\"r6\",\"path\":\"api/ping\"}")])
  (check-equal? (hash-ref (hash-ref (bytes->jsexpr b) 'error) 'code) "unsupported-version"))

;; invoke: malformed envelope
(let-values ([(_st b) (call "POST" "/glaze/invoke" "{\"glz\":1}")])
  (check-equal? (hash-ref (hash-ref (bytes->jsexpr b) 'error) 'code) "bad-envelope"))

;; invoke: handler exception -> internal typed error, never the message
(let-values ([(_st b)
              (call "POST" "/glaze/invoke" "{\"glz\":1,\"id\":\"r7\",\"path\":\"api/boom\"}")])
  (define out (bytes->jsexpr b))
  (check-equal? (hash-ref (hash-ref out 'error) 'code) "internal")
  (check-false (string-contains? (bytes->string/utf-8 b) "SECRET-DB-PATH")
               "internal errors never leak exception text"))

;; invoke: invalid args -> invalid-args
(let-values ([(_st b)
              (call "POST"
                    "/glaze/invoke"
                    "{\"glz\":1,\"id\":\"r8\",\"path\":\"api/items\",\"args\":{\"name\":42}}")])
  (check-equal? (hash-ref (hash-ref (bytes->jsexpr b) 'error) 'code) "invalid-args"))

;; invoke: timeout abandons the waiter with a typed error
(let-values ([(_st b) (call "POST"
                            "/glaze/invoke"
                            "{\"glz\":1,\"id\":\"r9\",\"path\":\"api/slow\",\"timeout_ms\":100}")])
  (define timed-out (bytes->jsexpr b))
  (check-equal? (hash-ref (hash-ref timed-out 'error) 'code) "timed-out")
  (check-equal? (hash-ref timed-out 'outcome) "timed-out" "outcome names the terminal")
  (check-equal? (hash-ref (hash-ref timed-out 'error) 'data) 'null "missing error data is JSON null")
  (check-not-false (sync/timeout 2 (thread-dead-evt (unbox slow-handler-thread)))
                   "a timed-out handler can finish without leaking on result publication"))

;; invoke + cancel: the cooperative handler observes cancellation
(let-values ([(_st b)
              (let ()
                (define worker
                  (thread (lambda ()
                            (sleep 0.1)
                            (call "POST" "/glaze/cancel" "{\"glz\":1,\"id\":\"r10\"}"))))
                (define-values (st b)
                  (call "POST" "/glaze/invoke" "{\"glz\":1,\"id\":\"r10\",\"path\":\"api/slow\"}"))
                (thread-wait worker)
                (values st b))])
  (define out (bytes->jsexpr b))
  (check-true (hash-ref out 'ok))
  (check-equal? (hash-ref out 'value) "cancelled" "cooperative handler observed the cancel"))

;; A handler that accepts cancellation raises the typed terminal; the invoke
;; owns exactly one Keel outcome even though cancel is a separate request.
(let-values ([(_st b) (let ()
                        (define worker
                          (thread (lambda ()
                                    (sleep 0.1)
                                    (call "POST" "/glaze/cancel" "{\"glz\":1,\"id\":\"r11\"}"))))
                        (define-values (st b)
                          (call "POST"
                                "/glaze/invoke"
                                "{\"glz\":1,\"id\":\"r11\",\"path\":\"api/cancel-aware\"}"))
                        (thread-wait worker)
                        (values st b))])
  (define out (bytes->jsexpr b))
  (check-false (hash-ref out 'ok))
  (check-equal? (hash-ref out 'outcome) "cancelled")
  (check-equal? (hash-ref (hash-ref out 'error) 'code) "cancelled"))

;; cancel of an unknown id is an idempotent success
(let-values ([(_st b) (call "POST" "/glaze/cancel" "{\"glz\":1,\"id\":\"nope\"}")])
  (check-true (hash-ref (bytes->jsexpr b) 'ok)))

;; ---- event sequence numbers over SSE ----

(define sse-frames (make-channel))
(define sse-reader
  (thread (lambda ()
            (define-values (_st _h in)
              (http-sendrecv "127.0.0.1" "/glaze/events" #:port port #:ssl? #f #:method "GET"))
            (define (read-frame)
              ;; lines up to the blank line that terminates one SSE frame
              (let loop ([acc '()])
                (define line (read-line in 'any))
                (cond
                  [(or (eof-object? line) (and (string? line) (string=? line ""))) (reverse acc)]
                  [else (loop (cons line acc))])))
            (channel-put sse-frames (read-frame))
            (channel-put sse-frames (read-frame)))))
(let ([deadline (+ (current-inexact-milliseconds) 5000)])
  (let loop ()
    (unless (or (positive? (bus-subscriber-count bus)) (>= (current-inexact-milliseconds) deadline))
      (sleep 0.01)
      (loop))))
(bus-broadcast! bus 'first (hasheq 'n 1))
(define frame1 (sync/timeout 5 sse-frames))
(check-true (and (list? frame1) (pair? frame1)) "received the first SSE frame")
(check-true (for/or ([line (in-list frame1)])
              (and (string? line) (string-prefix? line "id: ")))
            "SSE frames carry an id: line with the seq")
(bus-broadcast! bus 'second (hasheq 'n 2))
(define frame2 (sync/timeout 5 sse-frames))
(define (frame-seq f)
  (string->number (substring (for/or ([line (in-list f)]
                                      #:when (and (string? line) (string-prefix? line "id: ")))
                               line)
                             4)))
(check-true (< (frame-seq frame1) (frame-seq frame2)) "sequence numbers increase")

(shutdown)
(delete-directory/files dir)

;; ---- app lifecycle state machine (real native window) ----

(if (webview-supported?)
    (let ()
      (define dir2 (make-temporary-file "glz1-app-~a" 'directory))
      (define captured-app #f)
      (define (grab-app)
        (set! captured-app (current-app)))
      (call-with-output-file (build-path dir2 "index.html")
                             (lambda (o) (display "<h1>app</h1>" o))
                             #:exists 'replace)
      ;; Tray-resident mode: closing the last window does NOT quit; the app
      ;; survives, accepts another window, and quits on app-quit!. Everything
      ;; runs on the main thread from inside #:on-ready.
      (define-values (kind _teardown)
        (run-app #:public-dir dir2
                 #:port 18992
                 #:title "glz1 lifecycle"
                 #:events (make-event-bus)
                 #:quit-on-last-window? #f
                 #:on-ready (lambda (wv url)
                              (define the-app (current-app))
                              (grab-app)
                              (check-equal? (app-state the-app) 'ready "state at on-ready is ready")
                              ;; close the only window: tray mode must keep the app up
                              (webview-close wv)
                              (check-not-false (memq (app-state the-app) '(ready running))
                                               "app stays alive after last window closes (tray mode)")
                              ;; a second window attaches to the still-running app
                              (define wv2 (open-app-window url #:title "second"))
                              (check-not-false wv2 "second window attaches")
                              ;; and app-quit! ends it
                              (app-quit! the-app)
                              (check-equal? (app-state the-app) 'stopping "state at quit"))))
      (check-equal? kind 'webview)
      (check-equal? (app-state captured-app) 'stopped "app ends stopped")
      (check-exn exn:fail?
                 (lambda () (open-app-window "http://127.0.0.1:1/"))
                 "open-app-window after quit raises")
      (delete-directory/files dir2))
    (printf "glaze-test/bridge: skipping app lifecycle e2e — no native webview\n"))
