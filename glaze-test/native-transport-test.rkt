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
;;     the deliver! hook captured on a channel (no WebView involved).

(require rackunit
         racket/async-channel
         racket/file
         racket/string
         json
         glaze/api
         glaze/bridge
         glaze/capability
         glaze/events
         glaze/native-transport)

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

;; stats are observable
(define stats (native-transport-stats t))
(check-true (>= (hash-ref stats 'messages-received 0) 2) "messages were counted")
(check-true (>= (hash-ref stats 'responses-delivered 0) 2) "responses were counted")

(delete-directory/files capture-dir)
