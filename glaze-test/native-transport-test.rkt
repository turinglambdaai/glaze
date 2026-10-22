#lang racket/base

;; Native transport tests — headless, so they run on every CI platform.
;;
;; Covers the transport-neutral surface both adapters share:
;;   - dispatch-bridge / dispatch-invoke: hello, invoke (args as the
;;     handler's JSON body, path params), typed errors, timeouts,
;;     cooperative cancellation, capability checks;
;;   - static-resource: index fallback, nested files, traversal rejection,
;;     MIME table parity with the HTTP adapter;
;;   - the native page bindings: bootstrap + generated client invariants;
;;   - a full transport round trip through native-transport-message! with
;;     the deliver! hook captured on a channel (no WebView involved);
;;   - streaming-response delivery: open/chunk/end frames, UTF-8 chunk
;;     boundaries, writer failures, mid-stream cancellation.

(require rackunit
         racket/async-channel
         racket/file
         racket/list
         racket/string
         json
         glaze/api
         glaze/bridge
         glaze/capability
         glaze/events
         glaze/native-transport)

;; Negative-path tests intentionally raise handler errors; keep them off
;; stderr so drdr's non-empty-stderr check stays clean.
(current-glaze-error-reporter (lambda (_exn _uri) (void)))
(define (envelope-error resp)
  (hash-ref resp 'error #f))

;; ---- dispatch-invoke unit ----

(define routes
  (list (GET "api/ping" (lambda (req) (hasheq 'pong #t)))
        (GET "api/echo/:id" (lambda (req id) (hasheq 'id id)))
        (POST "api/echo" (lambda (req) (hasheq 'body (request-json-body req))))
        (GET "api/slow"
             (lambda (req)
               (sleep 1)
               (hasheq 'done #t)))
        (GET "api/boomer" (lambda (req) (error 'boomer "SECRET-INTERNALS")))
        (GET "api/protected" #:permission 'files:read (lambda (req) (hasheq 'secret #t)))
        (GET "api/admin" #:permission 'admin:all (lambda (req) (hasheq 'admin #t)))))

(define table (make-request-table))

;; happy path
(define ping-resp
  (dispatch-bridge (hasheq 'glz 1 'id "i1" 'path "api/ping") routes #f table route->js-name))
(check-true (hash-ref ping-resp 'ok) "ping invoke succeeds")
(check-equal? (hash-ref ping-resp 'outcome) "succeeded" "ping outcome names keel succeeded")
(check-equal? (hash-ref ping-resp 'value) (hasheq 'pong #t) "ping value passes through")

;; envelope args become the handler's JSON body
(define echo-resp
  (dispatch-bridge
   (hasheq 'glz 1 'id "i2" 'path "api/echo" 'method "POST" 'args (hasheq 'hello "world"))
   routes
   #f
   table
   route->js-name))
(check-equal? (hash-ref (hash-ref echo-resp 'value) 'body)
              (hasheq 'hello "world")
              "envelope args reach the handler as the JSON body")

;; path params
(define param-resp
  (dispatch-bridge (hasheq 'glz 1 'id "i3" 'path "api/echo/42") routes #f table route->js-name))
(check-equal? (hash-ref (hash-ref param-resp 'value) 'id) "42" "path params are captured")

;; typed errors
(check-false
 (hash-ref (dispatch-bridge (hasheq 'glz 1 'id "i4" 'path "api/nope") routes #f table route->js-name)
           'ok)
 "unknown route fails")
(check-equal?
 (envelope-error
  (dispatch-bridge (hasheq 'glz 1 'id "i5" 'path "api/nope") routes #f table route->js-name))
 (hasheq 'code "unknown-command" 'message "no route matches GET api/nope" 'data 'null)
 "unknown route is a typed unknown-command error")
(check-equal?
 (hash-ref (hash-ref (dispatch-bridge (hasheq 'glz 1 'id "i6" 'path "api/echo" 'method "DELETE")
                                      routes
                                      #f
                                      table
                                      route->js-name)
                     'error)
           'code)
 "method-not-allowed"
 "an explicit method with no matching route is method-not-allowed")
(check-equal?
 (hash-ref (hash-ref (dispatch-bridge (hasheq 'glz 1 'id "i7" 'path "api/ping" 'method "POST")
                                      routes
                                      #f
                                      table
                                      route->js-name)
                     'error)
           'code)
 "method-not-allowed"
 "explicit method mismatch is method-not-allowed")
(check-equal?
 (hash-ref (hash-ref (dispatch-bridge (hasheq 'glz 1 'id "i8" 'path "api/ping" 'method "PATCH")
                                      routes
                                      #f
                                      table
                                      route->js-name)
                     'error)
           'code)
 "bad-envelope"
 "a foreign HTTP method is a bad envelope")

;; missing id / empty id / missing path
(check-equal?
 (hash-ref (hash-ref (dispatch-bridge (hasheq 'glz 1 'path "api/ping") routes #f table route->js-name)
                     'error)
           'code)
 "bad-envelope"
 "missing id is a bad envelope")
(check-equal? (hash-ref (hash-ref (dispatch-bridge 42 routes #f table route->js-name) 'error) 'code)
              "bad-envelope"
              "a non-object message is a bad envelope")

;; internal errors never leak exception text
(define boom-resp
  (dispatch-bridge (hasheq 'glz 1 'id "i9" 'path "api/boomer") routes #f table route->js-name))
(check-false (hash-ref boom-resp 'ok) "raising handler fails")
(check-equal? (hash-ref (hash-ref boom-resp 'error) 'code) "internal" "raising handler is internal")
(check-false (string-contains? (format "~a" boom-resp) "SECRET-INTERNALS")
             "internal error never echoes exception text")

;; timeout
(define slow-resp
  (dispatch-bridge (hasheq 'glz 1 'id "i10" 'path "api/slow" 'timeout_ms 50)
                   routes
                   #f
                   table
                   route->js-name))
(check-equal? (hash-ref slow-resp 'outcome) "timed-out" "timeout_ms yields the timed-out outcome")
(check-equal? (hash-ref (hash-ref slow-resp 'error) 'code) "timed-out" "timeout error code")

;; capability enforcement
(define authority (make-capability "cap-test" '(files:read)))
(check-equal?
 (hash-ref
  (hash-ref
   (dispatch-bridge (hasheq 'glz 1 'id "i11" 'path "api/admin") routes authority table route->js-name)
   'error)
  'code)
 "capability-denied"
 "a route beyond the capability is denied")
(check-true (hash-ref (dispatch-bridge (hasheq 'glz 1 'id "i12" 'path "api/protected")
                                       routes
                                       authority
                                       table
                                       route->js-name)
                      'ok)
            "a route inside the capability succeeds")

;; op-routed hello over the shared dispatch
(define hello-resp
  (dispatch-bridge (hasheq 'glz 1 'op "hello" 'id "h1") routes #f table route->js-name))
(check-true (hash-ref hello-resp 'ok) "hello op succeeds")
(check-equal? (hash-ref (hash-ref hello-resp 'value) 'glz) 1 "hello manifest carries the version")
(check-true (hash? (hash-ref (hash-ref hello-resp 'value) 'schema))
            "hello manifest carries a keel schema")
(check-equal?
 (hash-ref (hash-ref (dispatch-bridge (hasheq 'glz 1 'op "hello") routes #f table route->js-name)
                     'error)
           'code)
 "bad-envelope"
 "hello without an id is a bad envelope")

;; ---- static-resource ----

(define dir (make-temporary-file "glaze-native-t-~a" 'directory))
(call-with-output-file (build-path dir "index.html")
                       (lambda (o) (display "<html>native-index</html>" o)))
(call-with-output-file (build-path dir "app.js") (lambda (o) (display "console.log(1)" o)))
(make-directory* (build-path dir "sub"))
(call-with-output-file (build-path dir "sub" "data.json") (lambda (o) (display "{\"k\":1}" o)))

(define-values (idx-mime idx-data) (static-resource dir '()))
(check-equal? idx-mime #"text/html; charset=utf-8" "root serves index.html with the html MIME")
(check-true (regexp-match? #rx#"native-index" idx-data) "root serves the index body")

(define-values (js-mime js-data) (static-resource dir '("app.js")))
(check-equal? js-mime #"application/javascript; charset=utf-8" "js MIME parity")

(define-values (sub-mime _) (static-resource dir '("sub" "data.json")))
(check-equal? sub-mime #"application/json; charset=utf-8" "nested file MIME")

(define-values (fb-mime fb-data) (static-resource dir '("no" "such" "path")))
(check-equal? fb-mime #"text/html; charset=utf-8" "SPA fallback serves index")
(check-true (regexp-match? #rx#"native-index" fb-data) "SPA fallback body is index")

(let-values ([(m d) (static-resource dir '(up "etc" "passwd"))])
  (check-false m "symbolic traversal segments never touch the filesystem")
  (check-false d "traversal serves no bytes"))
(let-values ([(m d) (static-resource dir '(".." "secrets"))])
  ;; Containment turns an escaped path into the SPA fallback, never the
  ;; file outside the root.
  (check-equal? m #"text/html; charset=utf-8" "escaped path falls back to index")
  (check-true (regexp-match? #rx#"native-index" d) "escaped path never serves outside bytes"))
(let-values ([(m d) (static-resource "/no/such/dir" '("index.html"))])
  (check-false m "a missing public dir serves nothing")
  (check-false d "a missing public dir serves no bytes"))

(delete-directory/files dir)

;; ---- page-side bindings ----

(define bs native-bootstrap-js)
(check-true (string-contains? bs "__glz1Deliver") "bootstrap installs the delivery hook")
(check-true (string-contains? bs "__glz1Events") "bootstrap installs the event hook")
(check-true (string-contains? bs "messageHandlers.glz1") "bootstrap posts to the glz1 handler")
(check-true (string-contains? bs "chrome.webview") "bootstrap covers the WebView2 bridge")
(check-true (string-contains? bs "addEventListener")
            "bootstrap subscribes the WebView2 delivery event")
(check-true (string-contains? bs "timeout_ms") "bootstrap forwards timeout_ms")

(define api-js (native-api-client-js routes))
(check-true (string-contains? api-js "ping: function") "generated client has the ping entry")
(check-true (string-contains? api-js "echoId: function") "generated client camel-cases path params")
(check-false (string-contains? api-js "fetch(") "native client never uses fetch")
(check-false (string-contains? api-js "window.webkit") "generated client is platform-neutral")
(check-true (string-contains? api-js "__glz1") "native client binds through __glz1")

;; ---- transport round trip (no WebView) ----

(define capture-dir (make-temporary-file "glaze-native-rt-~a" 'directory))
(call-with-output-file (build-path capture-dir "index.html")
                       (lambda (o) (display "<html>roundtrip</html>" o)))
(define t (start-native-transport #:api routes #:public-dir capture-dir))
(define delivered (make-async-channel))
(native-transport-set-deliver! t (lambda (js) (async-channel-put delivered js)))

(native-transport-message! t (jsexpr->string (hasheq 'glz 1 'op "hello" 'id "rt-hello")))
(define hello-d (sync/timeout 5 delivered))
(check-not-false hello-d "hello delivery arrives")
(define hello-js (and hello-d (native-delivery-js hello-d)))
(check-true (and hello-js (string-contains? hello-js "__glz1Deliver"))
            "hello delivery targets the page hook")
(check-true (and hello-js (string-contains? hello-js "rt-hello"))
            "hello delivery carries the request id")

(native-transport-message! t "{\"glz\":1,\"id\":\"rt-ping\",\"path\":\"api/ping\"}")
(define ping-d (sync/timeout 5 delivered))
(check-not-false ping-d "invoke delivery arrives")
(define ping-js (and ping-d (native-delivery-js ping-d)))
(define ping-json (and ping-d (native-delivery-json ping-d)))
;; The JS carrier wraps the response as a JSON text inside a JSON string
;; literal (the page does one JSON.parse); the JSON carrier is the bare
;; response for PostWebMessageAsJson-style hosts.
(check-true (and ping-js (string-contains? ping-js "rt-ping"))
            "invoke delivery carries the request id")
(check-true (and ping-js (string-contains? ping-js "succeeded"))
            "invoke delivery carries the outcome")
(check-true (and ping-json (string-contains? ping-json "\"pong\":true"))
            "json carrier carries the result for WebView2 hosts")

;; events flow through the delivery hook with sequence numbers
(define bus (make-event-bus))
(define t2 (start-native-transport #:api routes #:events bus #:public-dir capture-dir))
(define delivered2 (make-async-channel))
(native-transport-set-deliver! t2 (lambda (js) (async-channel-put delivered2 js)))
(bus-broadcast! bus 'counter-changed (hasheq 'value 7))
(define event-d (sync/timeout 5 delivered2))
(check-not-false event-d "event delivery arrives")
(define event-js (and event-d (native-delivery-js event-d)))
(check-true (and event-js (string-contains? event-js "__glz1Events"))
            "event delivery targets the page hook")
(check-true (and event-js (string-contains? event-js "counter-changed"))
            "event delivery carries the name")
(check-true (and event-js (string-contains? event-js "\"value\":7"))
            "event delivery carries the payload")

;; shutdown stops deliveries without raising
(check-not-exn (lambda () (native-transport-shutdown! t)))
(check-not-exn (lambda () (native-transport-shutdown! t2)))

;; The event subscription is gone and no page callback runs after shutdown.
(bus-broadcast! bus 'after-shutdown (hasheq 'value 8))
(check-false (sync/timeout 0.1 delivered2) "events are not delivered after shutdown")
(check-not-exn (lambda () (native-transport-shutdown! t2)) "event shutdown is idempotent")

;; stats are observable
(define stats (native-transport-stats t))
(check-true (>= (hash-ref stats 'messages-received 0) 2) "messages were counted")
(check-true (>= (hash-ref stats 'responses-delivered 0) 2) "responses were counted")

;; Closed transports ignore new native and deferred messages without queuing
;; work or reopening their dispatcher.
(define messages-before-closed-send
  (hash-ref (native-transport-stats t) 'messages-received 0))
(native-transport-message! t (jsexpr->string (hasheq 'glz 1 'id "after-close" 'path "api/ping")))
(native-transport-message-deferred! t "deferred-after-close")
(check-equal? (native-transport-take-deferred! t) '() "closed transport drops deferred messages")
(sleep 0.05)
(check-equal? (hash-ref (native-transport-stats t) 'messages-received 0)
              messages-before-closed-send
              "closed transport does not queue new native messages")
(check-not-exn (lambda () (native-transport-shutdown! t)) "shutdown is idempotent")

(delete-directory/files capture-dir)

;; ---- streaming responses over the native channel ----
;; A handler that returns streaming-response delivers an open frame, one
;; chunk frame per drained piece of text, and a terminal frame; the page's
;; invokeStream joins them into the invoke's full value. Also covers UTF-8
;; chunk boundaries, writer failures, and mid-stream cancellation.

(define (collect-stream-frames ch)
  ;; deliveries until the terminal frame, as their js snippets
  (let loop ([acc '()])
    (define d (sync/timeout 10 ch))
    (unless d
      (error 'collect-stream-frames "no delivery within 10s"))
    (define js (native-delivery-js d))
    (if (string-contains? js "__glz1End")
        (reverse (cons js acc))
        (loop (cons js acc)))))

(define (chunk-texts frames)
  (for/list ([js (in-list frames)]
             #:when (string-contains? js "__glz1Chunk"))
    (define m (regexp-match #rx"__glz1Chunk\\(\"[^\"]*\",\"(.*)\"\\);" js))
    (and m (read-json (open-input-string (string-append "\"" (cadr m) "\""))))))

(define stream-dir (make-temporary-file "glaze-native-stream-~a" 'directory))
(call-with-output-file (build-path stream-dir "index.html")
                       (lambda (o) (display "<html>stream</html>" o)))
(define stream-routes
  (list (POST "api/llm/chat"
              (lambda (_req)
                (streaming-response (lambda (out)
                                      (display "Hel" out)
                                      (flush-output out)
                                      (display "lo" out)
                                      (flush-output out)
                                      ;; "水" is three UTF-8 bytes split across two writes:
                                      ;; the transport must hold the incomplete tail
                                      (write-byte 230 out)
                                      (flush-output out)
                                      (sleep 0.05)
                                      (write-byte 176 out)
                                      (write-byte 180 out)
                                      (flush-output out)
                                      (display "!" out)
                                      (flush-output out)))))
        (GET "api/stream-boom"
             (lambda (_req)
               (streaming-response (lambda (out)
                                     (display "partial" out)
                                     (flush-output out)
                                     (error 'writer "mid-stream failure")))))
        (GET "api/stream-forever"
             (lambda (_req)
               (streaming-response (lambda (out)
                                     (let loop ()
                                       (display "tick " out)
                                       (flush-output out)
                                       (sleep 0.05)
                                       (loop))))))))
(define t3 (start-native-transport #:api stream-routes #:public-dir stream-dir))
(define delivered3 (make-async-channel))
(native-transport-set-deliver! t3 (lambda (js) (async-channel-put delivered3 js)))

;; happy path: open frame, chunk frames, terminal frame, joined text
(native-transport-message!
 t3
 (jsexpr->string (hasheq 'glz 1 'id "s1" 'path "api/llm/chat" 'method "POST")))
(define frames (collect-stream-frames delivered3))
(check-true (string-contains? (first frames) "__glz1StreamOpen") "stream opens with the open frame")
(check-true (string-contains? (first frames) "s1") "open frame carries the request id")
(check-true (string-contains? (last frames) "__glz1End") "stream closes with the terminal frame")
(check-true (andmap (lambda (js) (string-contains? js "__glz1Chunk")) (drop-right (rest frames) 1))
            "middle frames are chunk frames")
(check-equal? (apply string-append (chunk-texts frames))
              "Hello水!"
              "chunk texts join across a UTF-8 boundary")

;; a writer failure mid-stream still delivers the terminal frame
(native-transport-message! t3 (jsexpr->string (hasheq 'glz 1 'id "s2" 'path "api/stream-boom")))
(define boom-frames (collect-stream-frames delivered3))
(check-true (string-contains? (first boom-frames) "__glz1StreamOpen") "booming stream opens")
(check-equal? (chunk-texts boom-frames) (list "partial") "chunks before the failure arrive")
(check-true (string-contains? (last boom-frames) "__glz1End")
            "a writer failure still terminates the stream")

;; mid-stream cancel closes the pipe and settles the stream
(native-transport-message! t3 (jsexpr->string (hasheq 'glz 1 'id "s3" 'path "api/stream-forever")))
(define open-d (sync/timeout 5 delivered3))
(check-true (and open-d (string-contains? (native-delivery-js open-d) "__glz1StreamOpen"))
            "endless stream opens")
(check-not-false (sync/timeout 5 delivered3) "endless stream produces at least one chunk")
(native-transport-message! t3 (jsexpr->string (hasheq 'glz 1 'op "cancel" 'id "s3")))
(check-not-exn (lambda () (collect-stream-frames delivered3))
               "cancel settles the stream with the terminal frame")

;; the page bindings expose the streaming client
(check-true (string-contains? native-bootstrap-js "__glz1StreamOpen") "bootstrap handles stream open")
(check-true (string-contains? native-bootstrap-js "__glz1Chunk") "bootstrap handles stream chunks")
(check-true (string-contains? native-bootstrap-js "__glz1End") "bootstrap handles stream end")
(check-true (string-contains? native-bootstrap-js "invokeStream") "bootstrap exposes invokeStream")
(check-true (string-contains? (native-api-client-js stream-routes) "glaze.invokeStream")
            "generated client exposes invokeStream")

(check-not-exn (lambda () (native-transport-shutdown! t3)))

;; ---- shutdown owns active stream writers and delivery lifecycle ----

(define (make-shutdown-stream-routes started finished)
  (list
   (GET "api/shutdown-stream"
        (lambda (_req)
          (streaming-response
           (lambda (out)
             (dynamic-wind
              void
              (lambda ()
                (let loop ()
                  (async-channel-put started 'tick)
                  (display "tick" out)
                  (flush-output out)
                  (sleep 0.01)
                  (loop)))
              (lambda () (async-channel-put finished 'finished)))))))))

(define shutdown-dir (make-temporary-file "glaze-native-shutdown-~a" 'directory))
(call-with-output-file (build-path shutdown-dir "index.html")
  (lambda (o) (display "<html>shutdown</html>" o)))

;; Shutting down an active stream closes its writer, clears its registration,
;; and prevents a callback from starting after shutdown returns.
(define shutdown-started (make-async-channel))
(define shutdown-finished (make-async-channel))
(define shutdown-deliveries (make-async-channel))
(define shutdown-returned? (box #f))
(define shutdown-late-delivery? (box #f))
(define t4
  (start-native-transport
   #:api (make-shutdown-stream-routes shutdown-started shutdown-finished)
   #:public-dir shutdown-dir))
(native-transport-set-deliver!
 t4
 (lambda (delivery)
   (when (unbox shutdown-returned?)
     (set-box! shutdown-late-delivery? #t))
   (async-channel-put shutdown-deliveries delivery)))
(native-transport-message!
 t4
 (jsexpr->string (hasheq 'glz 1 'id "shutdown-stream" 'path "api/shutdown-stream")))
(define shutdown-open (sync/timeout 5 shutdown-deliveries))
(check-true (and shutdown-open
                  (string-contains? (native-delivery-js shutdown-open) "__glz1StreamOpen"))
            "active stream opens before shutdown")
(check-not-false (sync/timeout 5 shutdown-started) "stream writer starts before shutdown")
(check-not-exn (lambda () (native-transport-shutdown! t4)) "shutdown closes active stream")
(set-box! shutdown-returned? #t)
(check-not-false (sync/timeout 5 shutdown-finished) "shutdown unblocks and finishes stream writer")
(check-not-exn (lambda () (native-transport-shutdown! t4)) "active stream shutdown is idempotent")
(native-transport-message! t4 (jsexpr->string (hasheq 'glz 1 'id "late" 'path "api/ping")))
(sleep 0.05)
(check-false (unbox shutdown-late-delivery?) "no callback begins after shutdown returns")

;; Cancellation and two concurrent shutdown callers may race; all must settle,
;; and the active writer must terminate whichever operation wins the lock.
(define race-started (make-async-channel))
(define race-finished (make-async-channel))
(define race-deliveries (make-async-channel))
(define race-returned? (box #f))
(define race-late-delivery? (box #f))
(define t5
  (start-native-transport
   #:api (make-shutdown-stream-routes race-started race-finished)
   #:public-dir shutdown-dir))
(native-transport-set-deliver!
 t5
 (lambda (delivery)
   (when (unbox race-returned?)
     (set-box! race-late-delivery? #t))
   (async-channel-put race-deliveries delivery)))
(native-transport-message!
 t5
 (jsexpr->string (hasheq 'glz 1 'id "race-stream" 'path "api/shutdown-stream")))
(define race-open (sync/timeout 5 race-deliveries))
(check-true (and race-open
                  (string-contains? (native-delivery-js race-open) "__glz1StreamOpen"))
            "race stream opens")
(check-not-false (sync/timeout 5 race-started) "race stream writer starts")
(define race-gate (make-semaphore 0))
(define race-results (make-async-channel))
(define cancel-thread
  (thread
   (lambda ()
     (sync race-gate)
     (native-transport-message!
      t5
      (jsexpr->string (hasheq 'glz 1 'op "cancel" 'id "race-stream")))
     (async-channel-put race-results 'cancel-submitted))))
(define shutdown-thread-1
  (thread
   (lambda ()
     (sync race-gate)
     (native-transport-shutdown! t5)
     (set-box! race-returned? #t)
     (async-channel-put race-results 'shutdown-1))))
(define shutdown-thread-2
  (thread
   (lambda ()
     (sync race-gate)
     (native-transport-shutdown! t5)
     (set-box! race-returned? #t)
     (async-channel-put race-results 'shutdown-2))))
(for ([i (in-range 3)]) (semaphore-post race-gate))
(define race-outcomes
  (for/list ([i (in-range 3)]) (sync/timeout 5 race-results)))
(check-equal? (sort (filter symbol? race-outcomes) symbol<?)
              '(cancel-submitted shutdown-1 shutdown-2)
              "cancel and concurrent shutdown callers all settle")
(thread-wait cancel-thread)
(thread-wait shutdown-thread-1)
(thread-wait shutdown-thread-2)
(check-not-false (sync/timeout 5 race-finished) "racing shutdown closes stream writer")
(sleep 0.05)
(check-false (unbox race-late-delivery?) "no callback begins after racing shutdown returns")
(check-not-exn (lambda () (native-transport-shutdown! t5)) "racing shutdown remains idempotent")

;; If shutdown wins before a streaming response registers, the late
;; registration is rejected: the writer never starts and no open frame leaks.
(define late-stream-entered (make-async-channel))
(define late-stream-release (make-semaphore 0))
(define late-stream-returned (make-async-channel))
(define late-stream-writer-started (make-async-channel))
(define late-stream-deliveries (make-async-channel))
(define t6
  (start-native-transport
   #:api
   (list
    (GET "api/late-stream"
         (lambda (_req)
           (async-channel-put late-stream-entered 'entered)
           (sync late-stream-release)
           (async-channel-put late-stream-returned 'returning)
           (streaming-response
            (lambda (out)
              (async-channel-put late-stream-writer-started 'started)
              (display "must-not-start" out))))))
   #:public-dir shutdown-dir))
(native-transport-set-deliver! t6 (lambda (delivery) (async-channel-put late-stream-deliveries delivery)))
(native-transport-message!
 t6
 (jsexpr->string (hasheq 'glz 1 'id "late-stream" 'path "api/late-stream")))
(check-not-false (sync/timeout 5 late-stream-entered) "late stream route enters before shutdown")
(check-not-exn (lambda () (native-transport-shutdown! t6)) "shutdown may win before stream registration")
(semaphore-post late-stream-release)
(check-not-false (sync/timeout 5 late-stream-returned) "blocked route is released after shutdown")
(check-false (sync/timeout 0.1 late-stream-writer-started) "late stream writer is never started")
(check-false (sync/timeout 0.1 late-stream-deliveries) "late stream emits no frame after shutdown")

(delete-directory/files shutdown-dir)

(delete-directory/files stream-dir)
