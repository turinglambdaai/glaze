#lang racket/base

;; Browser-side artifacts for the native carrier. This module is deliberately
;; pure: host lifecycle and delivery threads stay in native-transport.rkt.

(require racket/list
         racket/string
         (only-in keel
                  schema-command
                  schema-command-error-codes
                  schema-command-parameters
                  schema-command-result)
         "../api.rkt"
         "../bridge.rkt"
         "../types.rkt")

(provide generate-api-declarations
         route-named-types
         native-api-client-js
         native-bootstrap-js)

;; ---- typed client declarations (/glaze/api.d.ts) ----

;; Renders the .d.ts for the app's TYPED routes (routes without a declared
;; schema keep their JS entry from api.js and are not typed yet). Function
;; names match the generated JS client (route->js-name).
(define (generate-api-declarations routes)
  (define typed (filter route-schema routes))
  (define commands
    (for/list ([r (in-list typed)])
      (schema-command (route->js-name (route-segments r))
                      (schema-command-parameters (route-schema r))
                      (schema-command-result (route-schema r))
                      (schema-command-error-codes (route-schema r)))))
  (define named
    (remove-duplicates (append* (map route-named-types typed))
                       #:key (lambda (d)
                               (if (grecord? d)
                                   (grecord-name d)
                                   (genum-name d)))))
  (generate-ts-declarations commands named))

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
      if (d && d.glz === 1 && d.stream === "open") { window.__glz1StreamOpen(d.id); }
      else if (d && d.glz === 1 && d.stream === "chunk") { window.__glz1Chunk(d.id, d.text); }
      else if (d && d.glz === 1 && d.stream === "end") { window.__glz1End(d.id); }
      else if (d && d.glz === 1 && d.id) { window.__glz1Deliver(d.id, JSON.stringify(d)); }
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
  // Streaming responses: the backend opens with __glz1StreamOpen, sends
  // __glz1Chunk per piece of text, and settles the promise on __glz1End.
  // An invoke that errors before the stream opens still arrives through
  // __glz1Deliver as a normal envelope, so both terminal shapes resolve
  // the same pending entry.
  window.__glz1StreamOpen = function (id) {
    var p = pending[id];
    if (p && !p.stream) { p.stream = { text: "" }; }
  };
  window.__glz1Chunk = function (id, text) {
    var p = pending[id];
    if (p && p.stream) {
      p.stream.text += text;
      if (p.onDelta) { try { p.onDelta(text); } catch (e) {} }
    }
  };
  window.__glz1End = function (id) {
    var p = pending[id];
    if (p && p.stream) {
      delete pending[id];
      p.resolve(p.stream.text);
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
        pending[id] = { resolve: resolve, reject: reject, onDelta: opts.onDelta };
        send(env);
      });
    },
    // Streaming invoke: the promise settles with the full text on the
    // terminal frame; opts.onDelta fires per chunk as it arrives. No
    // timeout_ms — a stream settles when the writer finishes. opts.signal
    // (an AbortSignal) rejects the promise at once and sends the cancel
    // op, which closes the stream's pipe server side.
    invokeStream: function (path, args, opts) {
      opts = opts || {};
      return new Promise(function (resolve, reject) {
        var id = "r" + (++seq) + "-" + Date.now();
        var env = { glz: 1, id: id, path: path, args: args || {} };
        if (opts.method) { env.method = opts.method; }
        pending[id] = { resolve: resolve, reject: reject, onDelta: opts.onDelta };
        if (opts.signal) {
          if (opts.signal.aborted) {
            delete pending[id];
            reject(new Error("aborted"));
            return;
          }
          opts.signal.addEventListener("abort", function () {
            var p = pending[id];
            if (p) {
              delete pending[id];
              p.reject(new Error("aborted"));
            }
            send({ glz: 1, op: "cancel", id: id });
          });
        }
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
                 "  glaze.invokeStream = g.invokeStream;\n"
                 "  glaze.cancel = g.cancel;\n"
                 "  glaze.hello = g.hello;\n"
                 "})();\n"
                 "glaze.api = {\n"
                 (api-client-entries api-routes)
                 "\n};\n"))
