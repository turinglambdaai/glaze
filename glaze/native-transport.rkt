#lang racket/base

;; The native host transport (docs/architecture-1.0.md) and the pieces the
;; HTTP development adapter shares with it.
;;
;; In a packaged app the WebView never talks to a TCP port. The page loads
;; its frontend resources from a controlled scheme (glaze://app/... served by
;; the host's WKURLSchemeHandler / WebView2 equivalent) and calls the backend
;; through the WebView's native message handler with the same GLZ1 envelopes
;; the HTTP adapter speaks. The loopback HTTP server survives as the
;; development adapter (hot reload, curl, tests); it is no longer the
;; production trust boundary.
;;
;; Everything on this side of the host boundary is transport-neutral and
;; shared verbatim by both adapters:
;;
;;   - dispatch-bridge / dispatch-invoke: GLZ1 envelope dispatch (op-routed
;;     hello / cancel / invoke) against the route table, with typed errors,
;;     cooperative cancellation, bounded timeouts, and capability checks —
;;     the exact pipeline server.rkt used to own;
;;   - static-resource: the static file rules (string segments only,
;;     filesystem containment, SPA index fallback, MIME table);
;;   - native-api-client-js / native-bootstrap-js: the page-side bindings
;;     that make the generated glaze.api entries and event delivery run over
;;     the message handler instead of fetch/EventSource.
;;
;; The host side (per platform) only has to: serve scheme resources through
;; static-resource, feed message-handler payloads into
;; native-transport-message!, and deliver the returned JavaScript snippets
;; back into the page on the UI thread (native-transport-deliver!).

(require json
         racket/async-channel
         racket/file
         racket/list
         racket/match
         racket/path
         racket/promise
         racket/string
         net/url
         (only-in web-server/http/request-structs make-request)
         (only-in web-server/http/response-structs response?)
         "api.rkt"
         "bridge.rkt"
         "capability.rkt"
         "events.rkt")

(provide dispatch-bridge
         dispatch-invoke
         synthetic-request
         static-resource
         path->mime-type
         current-glaze-error-reporter
         glz1-error-envelope
         native-transport?
         native-transport-routes
         native-delivery
         native-delivery-js
         native-delivery-json
         start-native-transport
         native-transport-message!
         native-transport-set-deliver!
         native-transport-public-dir
         native-transport-stats
         native-transport-count-resource!
         native-transport-shutdown!
         native-scheme-segments
         native-app-origin
         native-api-client-js
         native-bootstrap-js)

;; Exception reporter for handler failures (the internal-error path). Lives
;; here — not in server.rkt — because native-transport worker threads report
;; through it too. Default logs to stderr; run-app parameterizes this to its
;; #:on-error callback.
(define current-glaze-error-reporter
  (make-parameter
   (lambda (exn uri)
     (fprintf (current-error-port) "[glaze] handler error on ~a: ~a\n" uri (exn-message exn)))))

;; ---- error envelope ----

;; The outcome field uses keel's request vocabulary; ok #f always names a
;; failed/cancelled/timed-out terminal, and the error object is keel-shaped.
(define (glz1-error-envelope id code message data)
  (hasheq 'glz
          glz1-version
          'id
          id
          'ok
          #f
          'outcome
          (outcome-for-code code)
          'error
          (bridge-error-object code message data)))

;; ---- dispatch core ----

;; Route lookup from envelope parts — the GLZ1 invoke names its target in
;; the envelope, not in a request URI.
(define (find-api-match-by-parts api-routes method segments)
  (for/or ([r (in-list api-routes)])
    (define captured (route-match r method segments))
    (and captured (list r captured))))

;; A minimal web-server request for handlers invoked through the native
;; transport. Handlers receive the envelope's args as their JSON body, like
;; the HTTP adapter's rewritten request.
(define (synthetic-request method path body-bytes)
  (make-request (string->bytes/latin-1 (symbol->string (or method 'GET)))
                (string->url (string-append "glaze://app/" path))
                '()
                (delay
                  '())
                body-bytes
                "127.0.0.1"
                0
                "native"))

;; POST /glaze/invoke (HTTP) and the message-handler invoke (native) share
;; this pipeline: envelope parse, route match, capability check, handler
;; invocation with a bounded async result path, and typed terminal outcomes.
;; The only transport difference is how the handler's request struct is
;; built; #:make-handler-request receives (method path body-bytes).
;;
;; Returns the response jsexpr, or a raw web-server response? when a handler
;; produces a full/streaming response — the HTTP adapter passes those to the
;; connection untouched; the native transport answers a typed error instead
;; (there is no wire to stream onto once the envelope is committed).
(define (dispatch-invoke body
                         routes
                         authority
                         table
                         #:make-handler-request [make-handler-request synthetic-request])
  (define-values (parse-result parse-error)
    (with-handlers ([exn:fail:glaze:bridge?
                     (lambda (e)
                       (values #f
                               (glz1-error-envelope #f
                                                    (exn:fail:glaze:bridge-code e)
                                                    (exn-message e)
                                                    (exn:fail:glaze:bridge-data e))))])
      (values (call-with-values (lambda () (parse-invoke-envelope body)) list) #f)))
  (cond
    [parse-error parse-error]
    [else
     (define id (list-ref parse-result 0))
     (define path (list-ref parse-result 1))
     (define method-sym (list-ref parse-result 2))
     (define args (list-ref parse-result 3))
     (define segments (filter (lambda (sg) (not (equal? sg ""))) (string-split path "/")))
     ;; An explicit envelope method must match exactly; without one, GET
     ;; wins, then the mutating methods in registration order.
     (define match
       (cond
         [method-sym (find-api-match-by-parts routes method-sym segments)]
         [else
          (or (find-api-match-by-parts routes 'GET segments)
              (for/or ([mth (in-list '(POST PUT DELETE))])
                (find-api-match-by-parts routes mth segments)))]))
     (define method-mismatch?
       (and method-sym
            (not match)
            (for/or ([mth (in-list '(GET POST PUT DELETE))])
              (find-api-match-by-parts routes mth segments))))
     (cond
       [(not match)
        (glz1-error-envelope id
                             (if method-mismatch? 'method-not-allowed 'unknown-command)
                             (format "no route matches ~a ~a" (or method-sym 'GET) path)
                             'null)]
       [(and authority
             (route-permission (first match))
             (not (capability-has-permission? authority (route-permission (first match)))))
        (glz1-error-envelope id 'capability-denied "capability denied API route" 'null)]
       [else
        (define route (first match))
        (define captured (second match))
        (define timeout-secs
          (let ([ms (and (hash? body) (hash-ref body 'timeout_ms #f))])
            (and (exact-positive-integer? ms) (/ ms 1000.0))))
        (call-with-bridge-request
         table
         id
         (lambda ()
           ;; A timed-out caller stops receiving. A bounded async channel lets
           ;; the handler publish its eventual result and terminate instead
           ;; of leaking forever in a synchronous channel-put.
           (define result-ch (make-async-channel 1))
           (thread
            (lambda ()
              (async-channel-put
               result-ch
               (with-handlers
                   ([exn:fail:glaze:bridge? (lambda (e)
                                              (glz1-error-envelope id
                                                                   (exn:fail:glaze:bridge-code e)
                                                                   (exn-message e)
                                                                   (exn:fail:glaze:bridge-data e)))]
                    [exn:fail:glaze:bad-param?
                     (lambda (e) (glz1-error-envelope id 'invalid-args (exn-message e) 'null))]
                    [exn:fail? (lambda (e)
                                 ((current-glaze-error-reporter) e (string-append "glz1:" path))
                                 (glz1-error-envelope id 'internal "internal error" 'null))])
                 (define result
                   (parameterize ([current-capability-id (and authority (capability-id authority))]
                                  [current-capability-authorizer
                                   (and authority
                                        (lambda (permission resource)
                                          (capability-authorized? authority permission resource)))])
                     (apply (route-handler route)
                            (make-handler-request (or method-sym (route-method route))
                                                  path
                                                  (string->bytes/utf-8 (jsexpr->string args)))
                            captured)))
                 ;; Streaming and full-response handlers bypass
                 ;; the envelope: the wire is already committed.
                 (if (response? result)
                     result
                     (build-invoke-response id result))))))
           (define maybe-result
             (if timeout-secs
                 (sync/timeout timeout-secs result-ch)
                 (sync result-ch)))
           (cond
             [(not maybe-result)
              (glz1-error-envelope id
                                   'timed-out
                                   (format "handler exceeded ~ams" (hash-ref body 'timeout_ms))
                                   'null)]
             [else maybe-result])))])]))

;; The op-routed entry both transports share. Native messages carry an "op"
;; field ("hello" / "cancel"); anything with a path is an invoke. HTTP keeps
;; its own GET /glaze/hello and POST /glaze/cancel endpoints (same wire
;; shapes), and routes its invoke bodies through here as well.
(define (dispatch-bridge body routes authority table name-fn)
  (cond
    [(not (hash? body)) (glz1-error-envelope #f 'bad-envelope "message must be a JSON object" 'null)]
    [(equal? (hash-ref body 'op #f) "hello")
     (define id (hash-ref body 'id #f))
     (if (string? id)
         (build-invoke-response id (build-hello routes #f name-fn))
         (glz1-error-envelope #f 'bad-envelope "hello needs a non-empty id" 'null))]
    [(equal? (hash-ref body 'op #f) "cancel")
     (define id (hash-ref body 'id #f))
     (if (and (eq? (hash-ref body 'glz #f) glz1-version) (string? id) (not (string=? id "")))
         (begin
           (request-table-cancel! table id)
           (hasheq 'glz glz1-version 'id id 'ok #t 'value "cancel-signalled"))
         (glz1-error-envelope #f 'bad-envelope "cancel needs {glz:1, id}" 'null))]
    [else (dispatch-invoke body routes authority table)]))

;; ---- shared static resources ----

;; The static file rules both transports serve with: string segments only
;; (".." and "." arrive as path/param symbols and never touch the
;; filesystem), filesystem-level symlink containment, SPA index.html
;; fallback. Returns (values mime-type bytes) or (values #f #f).
(define (static-resource dir segments)
  (cond
    [(not (and (path-string? dir) (directory-exists? dir))) (values #f #f)]
    [(not (andmap string? segments)) (values #f #f)]
    [else
     (define candidate (apply build-path dir segments))
     (cond
       [(and (file-exists? candidate)
             (not (directory-exists? candidate))
             (static-file-contained? dir candidate))
        (values (path->mime-type candidate) (file->bytes candidate))]
       [else
        (define fallback (build-path dir "index.html"))
        (if (and (file-exists? fallback) (static-file-contained? dir fallback))
            (values (path->mime-type fallback) (file->bytes fallback))
            (values #f #f))])]))

;; Filesystem-level containment behind the lexical guard above: a symlink
;; inside public-dir must not smuggle a path outside it. Both sides resolve
;; every symlink component first (e.g. /tmp -> /private/tmp on macOS), so the
;; prefix check compares real locations, not spellings.
(define (static-file-contained? root candidate)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (path-inside? (canonical-path root) (canonical-path candidate))))

(define (path->mime-type p)
  (define ext (path-get-extension p))
  (cond
    [(not ext) #"application/octet-stream"]
    [(member ext '(#".html" #".htm")) #"text/html; charset=utf-8"]
    [(member ext '(#".css")) #"text/css; charset=utf-8"]
    [(member ext '(#".js" #".mjs")) #"application/javascript; charset=utf-8"]
    [(member ext '(#".json")) #"application/json; charset=utf-8"]
    [(member ext '(#".xml")) #"application/xml; charset=utf-8"]
    [(member ext '(#".txt")) #"text/plain; charset=utf-8"]
    [(member ext '(#".svg")) #"image/svg+xml"]
    [(member ext '(#".png")) #"image/png"]
    [(member ext '(#".jpg" #".jpeg")) #"image/jpeg"]
    [(member ext '(#".gif")) #"image/gif"]
    [(member ext '(#".webp")) #"image/webp"]
    [(member ext '(#".avif")) #"image/avif"]
    [(member ext '(#".ico")) #"image/x-icon"]
    [(member ext '(#".woff2")) #"font/woff2"]
    [(member ext '(#".woff")) #"font/woff"]
    [(member ext '(#".ttf")) #"font/ttf"]
    [(member ext '(#".otf")) #"font/otf"]
    [(member ext '(#".wasm")) #"application/wasm"]
    [(member ext '(#".mp4")) #"video/mp4"]
    [(member ext '(#".webm")) #"video/webm"]
    [(member ext '(#".ogg" #".ogv")) #"video/ogg"]
    [(member ext '(#".mp3")) #"audio/mpeg"]
    [(member ext '(#".map")) #"application/json; charset=utf-8"]
    [else #"application/octet-stream"]))

;; ---- native transport instance ----

;; One per window (per open-app call): receives message-handler payloads,
;; dispatches each on its own thread, and hands JavaScript snippets to the
;; host through the deliver! hook the platform wiring installs.
(struct native-transport
        (routes ; (listof route?)
         authority ; #f or capability?
         bus ; #f or event-bus?
         public-dir ; path-string? — scheme resources are served from here
         table ; request table (cancellation), per transport
         inbox ; async channel of raw message strings
         control ; async channel for the event thread's shutdown
         deliver-box ; box of (string? js) -> void — set by the host wiring
         stats-box ; box of immutable hash — served/delivered counters
         threads-box) ; box of (listof thread?) — dispatcher + event thread
  #:transparent)

(define (bump-stat! t key)
  (define box (native-transport-stats-box t))
  (set-box! box (hash-update (unbox box) key add1 0)))

;; One delivery to the page, in both carriers: `js` is a self-contained
;; JavaScript snippet for evaluateJavaScript-style hosts (WKWebView,
;; WebKitGTK); `json` is the bare JSON text for PostWebMessageAsJson-style
;; hosts (WebView2 delivers it as a parsed object on the message event).
;; Host wiring picks its carrier and hops it to the UI thread.
(struct native-delivery (js json) #:transparent)

;; JS snippet that resolves one pending invoke: the response travels as a
;; JSON text inside a JSON string literal, so no hand-rolled escaping is
;; needed and the page does one JSON.parse.
(define (deliver-response-js response)
  (define id (and (hash? response) (hash-ref response 'id #f)))
  (string-append "window.__glz1Deliver && window.__glz1Deliver("
                 (jsexpr->string (or id "unknown"))
                 ","
                 (jsexpr->string (jsexpr->string response))
                 ");"))

;; (list seq name data) from the event bus becomes one sequenced batch frame.
(define (events-deliver-js seq name data)
  (string-append "window.__glz1Events && window.__glz1Events("
                 (jsexpr->string (list seq
                                       (if (symbol? name)
                                           (symbol->string name)
                                           name)
                                       data))
                 ");"))

(define (start-native-transport #:api routes
                                #:authority [authority #f]
                                #:events [bus #f]
                                #:public-dir [public-dir "public"])
  (when (and authority (not (capability? authority)))
    (raise-argument-error 'start-native-transport "(or/c #f capability?)" authority))
  (when (and bus (not (event-bus? bus)))
    (raise-argument-error 'start-native-transport "event-bus?" bus))
  (define t
    (native-transport
     routes
     authority
     bus
     public-dir
     (make-request-table)
     (make-async-channel #f)
     (make-async-channel 1)
     (box void)
     (box
      (hasheq 'resources-served 0 'messages-received 0 'responses-delivered 0 'events-delivered 0))
     (box '())))
  ;; The dispatcher inherits the caller's parameterization (custodian, error
  ;; reporter) and spawns one thread per message, so a slow or timing-out
  ;; invoke never blocks other invokes or cancels.
  (define dispatcher (thread (lambda () (dispatcher-loop t))))
  ;; Subscribe BEFORE returning: an event broadcast right after
  ;; start-native-transport must be seen, exactly like the HTTP adapter's
  ;; SSE endpoint that is mounted before start-server returns.
  (define event-ch (and bus (bus-subscribe! bus)))
  (define event-thread (and bus (thread (lambda () (event-loop t event-ch)))))
  (set-box! (native-transport-threads-box t) (filter values (list dispatcher event-thread)))
  t)

(define (dispatcher-loop t)
  (let loop ()
    (define raw (async-channel-get (native-transport-inbox t)))
    (thread (lambda () (handle-raw-message! t raw)))
    (loop)))

;; Parse a raw message-handler payload (a JSON text from the page) and answer
;; through the host's deliver! hook. Parse failures become typed envelopes,
;; never host-side exceptions.
(define (handle-raw-message! t raw)
  (bump-stat! t 'messages-received)
  (define body
    (with-handlers ([exn:fail? (lambda (_) (hasheq))])
      (cond
        [(not (string? raw)) (hasheq)]
        [else (string->jsexpr raw)])))
  (define response
    (with-handlers ([exn:fail? (lambda (e)
                                 ((current-glaze-error-reporter) e "glz1:native")
                                 (glz1-error-envelope #f 'internal "internal error" 'null))])
      (dispatch-bridge body
                       (native-transport-routes t)
                       (native-transport-authority t)
                       (native-transport-table t)
                       route->js-name)))
  (bump-stat! t 'responses-delivered)
  ((unbox (native-transport-deliver-box t)) (native-delivery (deliver-response-js response)
                                                             (jsexpr->string response))))

(define (event-loop t ch)
  (define bus (native-transport-bus t))
  (let loop ()
    (define v (sync ch (native-transport-control t)))
    (cond
      [(eq? v 'shutdown) (bus-unsubscribe! bus ch)]
      [else
       (match-define (list seq name data) v)
       (bump-stat! t 'events-delivered)
       ((unbox (native-transport-deliver-box t))
        (native-delivery (events-deliver-js seq name data)
                         (jsexpr->string (list seq
                                               (if (symbol? name)
                                                   (symbol->string name)
                                                   name)
                                               data))))
       (loop)])))

;; Called by the host's message handler (on the UI thread); never blocks.
(define (native-transport-message! t raw)
  (async-channel-put (native-transport-inbox t) raw))

;; The host wiring installs this once it has a WebView handle: deliver! runs
;; on any transport thread and must hop the snippet to the UI thread.
(define (native-transport-set-deliver! t deliver!)
  (unless (procedure? deliver!)
    (raise-argument-error 'native-transport-set-deliver! "procedure?" deliver!))
  (set-box! (native-transport-deliver-box t) deliver!))

(define (native-transport-stats t)
  (unbox (native-transport-stats-box t)))

;; The host's scheme handler reports each served resource so tests can
;; observe that the page actually loaded through the controlled scheme.
(define (native-transport-count-resource! t)
  (bump-stat! t 'resources-served))

;; Stop the dispatcher and event threads. In-flight handler threads were
;; spawned under the caller's custodian and die with it (run-app teardown).
(define (native-transport-shutdown! t)
  ;; Idempotent: the host close path and run-app teardown both call this.
  ;; With no event bus nobody consumes the control channel, so a second
  ;; put would block forever on a full channel — only fire when threads
  ;; are still registered.
  (define threads (unbox (native-transport-threads-box t)))
  (unless (null? threads)
    (async-channel-put (native-transport-control t) 'shutdown)
    (for ([th (in-list threads)])
      (with-handlers ([exn:fail? (lambda (_) (void))])
        (kill-thread th)))
    (set-box! (native-transport-threads-box t) '())))

;; ---- scheme URL parsing (shared by every platform's scheme handler) ----

;; "glaze://app/sub/x.js?query#frag" -> '("sub" "x.js"), percent-decoded.
;; The host scheme handlers route on this, so a hostile or malformed URL
;; simply produces #f / non-"glaze" segments and falls to the 404 path.
(require (only-in net/uri-codec uri-decode))
;; WKWebView/WebKitGTK load the controlled scheme directly
;; (glaze://app/...). WebView2 refuses top-level navigation to custom
;; schemes — the exact reason Tauri uses http://tauri.localhost on
;; Windows — so the Windows host serves http://glaze.localhost/... and the
;; parser accepts both shapes.
(define (native-scheme-segments url-str)
  (define m
    (or (regexp-match #rx"^glaze://app/(.*)$" (or url-str ""))
        (regexp-match #rx"^https?://glaze[.]localhost/(.*)$" (or url-str ""))))
  (and m
       (let* ([rest (second m)]
              [path (car (regexp-split #rx"[?#]" rest))])
         (filter non-empty-string? (map uri-decode (string-split path "/"))))))
;; The origin the page runs on, per platform (for e2e assertions).
(define (native-app-origin)
  (if (eq? (system-type 'os) 'windows) "http://glaze.localhost/" "glaze://app/"))

;; ---- page-side bindings ----

;; Injected at document start by the host (WKUserScript and equivalents).
;; Defines the delivery plumbing and a transport-level client:
;; __glz1.invoke / cancel / hello / on. Host API differences are confined
;; to the `sink` selection (see the heredoc): WKWebView (macOS) and
;; WebKitGTK (Linux) share the webkit message-handler API, WebView2
;; (Windows) posts through window.chrome.webview and delivers
;; PostWebMessageAsJson back on the message event. The generated native
;; api.js (served by the scheme handler at /glaze/api.js) binds
;; glaze.call / glaze.api on top of this, so app HTML needs no changes
;; between adapters or platforms.
(define native-bootstrap-js
  #<<JS
(function () {
  if (window.__glz1) { return; }
  var pending = {};
  var seq = 0;
  var listeners = [];
  var sink = null;
  // WKWebView (macOS) and WebKitGTK (Linux) share the webkit
  // message-handler API; WebView2 (Windows) posts through
  // window.chrome.webview and delivers PostWebMessageAsJson back on the
  // message event.
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.glz1) {
    sink = { send: function (text) { window.webkit.messageHandlers.glz1.postMessage(text); } };
  } else if (window.chrome && window.chrome.webview) {
    sink = { send: function (text) { window.chrome.webview.postMessage(text); } };
    window.chrome.webview.addEventListener("message", function (e) {
      var d = e.data;
      if (d && d.glz === 1 && d.id) { window.__glz1Deliver(d.id, JSON.stringify(d)); }
    });
  }
  function send(envelope) {
    if (!sink) { throw new Error("native bridge unavailable"); }
    sink.send(JSON.stringify(envelope));
  }
  window.__glz1Deliver = function (id, text) {
    var p = pending[id];
    if (!p) { return; }
    delete pending[id];
    var out;
    try { out = JSON.parse(text); }
    catch (e) {
      out = { glz: 1, id: id, ok: false, outcome: "failed",
              error: { code: "internal", message: "undecodable response", data: null } };
    }
    if (out.ok) { p.resolve(out.value); }
    else {
      var err = new Error((out.error && out.error.message) || "bridge error");
      err.code = out.error && out.error.code;
      err.outcome = out.outcome;
      err.requestId = id;
      p.reject(err);
    }
  };
  window.__glz1Events = function (batch) {
    var arr;
    try { arr = JSON.parse(batch); } catch (e) { return; }
    arr.forEach(function (ev) {
      listeners.forEach(function (l) {
        if (l.name === ev[1]) { try { l.fn(ev[2]); } catch (e) {} }
      });
    });
  };
  function call(op) {
    return new Promise(function (resolve, reject) {
      var id = "r" + (++seq) + "-" + Date.now();
      var env = { glz: 1, id: id, op: op };
      pending[id] = { resolve: resolve, reject: reject };
      send(env);
    });
  }
  window.__glz1 = {
    invoke: function (path, args, opts) {
      opts = opts || {};
      return new Promise(function (resolve, reject) {
        var id = "r" + (++seq) + "-" + Date.now();
        var env = { glz: 1, id: id, path: path, args: args || {} };
        if (opts.method) { env.method = opts.method; }
        if (opts.timeoutMs) { env.timeout_ms = opts.timeoutMs; }
        pending[id] = { resolve: resolve, reject: reject };
        send(env);
      });
    },
    cancel: function (id) { send({ glz: 1, op: "cancel", id: id }); },
    hello: function () { return call("hello"); },
    on: function (name, fn) { listeners.push({ name: name, fn: fn }); }
  };
})();
JS
  )

;; The native twin of the HTTP api.js: same route entries (api-client-entries
;; from glaze/bridge), transport bindings over __glz1 instead of
;; fetch/EventSource. The scheme handler serves this at /glaze/api.js so an
;; app's existing <script src="/glaze/api.js"> works unchanged.
(define (native-api-client-js api-routes)
  (string-append "/* Generated by glaze (native transport) — do not edit. */\n"
                 "window.glaze = window.glaze || {};\n"
                 "(function () {\n"
                 "  var g = window.__glz1;\n"
                 "  if (!g) { throw new Error('glaze native bootstrap missing'); }\n"
                 "  glaze.call = function (method, path, body) {\n"
                 "    return g.invoke(path, body, { method: method });\n"
                 "  };\n"
                 "  glaze.on = function (name, fn) { g.on(name, fn); };\n"
                 "  glaze.invoke = g.invoke;\n"
                 "  glaze.cancel = g.cancel;\n"
                 "  glaze.hello = g.hello;\n"
                 "})();\n"
                 "glaze.api = {\n"
                 (api-client-entries api-routes)
                 "\n};\n"))
