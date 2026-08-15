#lang racket/base

;; Local HTTP server: static files (SPA fallback) + JSON API routes +
;; built-in infrastructure endpoints under /glaze/*:
;;
;;   GET /glaze/events   — Server-Sent Events stream (backend push; mounted
;;                         when start-server gets #:events (make-event-bus))
;;   GET /glaze/api.js   — generated JS client for the registered routes
;;                         (mounted unless #:serve-api-client? #f)
;;
;; Every request passes a Host-header check: the server must be addressed
;; as 127.0.0.1 / localhost / [::1] (with or without port). This closes the
;; DNS-rebinding hole where a malicious page resolves its own domain to the
;; loopback interface to reach the app's API from the browser.

(require racket/list
         web-server/web-server
         web-server/http/request-structs
         web-server/http/response-structs
         web-server/http/response
         net/url
         json
         racket/file
         racket/match
         racket/path
         racket/string
         racket/tcp
         "api.rkt"
         "events.rkt")

(provide start-dev-server
         start-server
         stop-server
         path->mime-type)

(define sse-path "glaze/events")
(define api-client-path "glaze/api.js")

;; Start a local HTTP server serving static files from public-dir on 127.0.0.1,
;; with optional JSON API routes (see api.rkt) and the built-in /glaze/*
;; endpoints. API routes match first; other requests fall through to static
;; files with SPA index.html fallback.
;; `start-server` is the canonical name used by both dev workflow and packaged
;; apps; `start-dev-server` is kept as a backward-compatible alias.
;; Returns (values port shutdown-proc). The returned port is the requested port
;; (the underlying web-server `serve` does not currently surface the actual
;; listening port when port 0 is requested).
(define (start-server #:port [port 8080]
                      #:public-dir [public-dir "public"]
                      #:api [api-routes '()]
                      #:events [event-bus #f]
                      #:serve-api-client? [serve-client? #t])
  (when (and event-bus (not (event-bus? event-bus)))
    (raise-argument-error 'start-server "event-bus?" event-bus))
  (define dispatcher (make-dispatcher public-dir api-routes port event-bus serve-client?))
  (define shutdown-server (serve #:dispatch dispatcher #:port port #:listen-ip "127.0.0.1"))
  ;; `serve` accepts the port synchronously but the accepting loop runs in a
  ;; background thread; if that thread dies (e.g. bind race), callers saw
  ;; only "connection refused" much later. Prove the listener is accepting
  ;; before returning — fail loudly, and never hand back a dead server.
  (wait-accepting! port shutdown-server)
  (values port shutdown-server))

(define (stop-server shutdown-proc)
  (shutdown-proc))

;; Backward-compatible alias. Prefer `start-server` in new code.
(define start-dev-server
  (make-keyword-procedure
   (lambda (kws kw-args . positional)
     (keyword-apply start-server kws kw-args positional))))

(define listen-wait-secs 3)

(define (wait-accepting! port shutdown-server)
  (define deadline (+ (current-inexact-milliseconds) (* listen-wait-secs 1000)))
  (define accepting?
    (let loop ()
      (define up?
        (with-handlers ([exn:fail:network? (lambda (e) #f)])
          (define-values (in out) (tcp-connect "127.0.0.1" port))
          (close-input-port in)
          (close-output-port out)
          #t))
      (cond
        [up? #t]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else (sleep 0.02) (loop)])))
  (unless accepting?
    (shutdown-server)
    (raise-arguments-error
     'start-server
     (format "listener on port ~a did not start accepting within ~as"
             port listen-wait-secs)
     "port" port)))

;; ---- Host-header validation (DNS-rebinding guard) ----

(define (host-allowed? req port)
  (define h (headers-assq #"Host" (request-headers/raw req)))
  (cond
    ;; No Host header (ancient clients, raw sockets): nothing was spoofed.
    [(not h) #t]
    [else
     (define host (bytes->string/latin-1 (header-value h)))
     (define bare (if (string-contains? host ":")
                      (substring host 0 (string-index-of host #\:))
                      host))
     (member bare (list "127.0.0.1" "localhost" "[::1]" "::1"))]))

(define (string-index-of s ch)
  (for/or ([c (in-string s)] [i (in-naturals)] #:when (char=? c ch)) i))

;; ---- dispatcher ----

(define (make-dispatcher public-dir api-routes port event-bus serve-client?)
  (lambda (conn req)
    (define resp
      (cond
        [(not (host-allowed? req port)) (error-response 403 "host not allowed")]
        [(find-api-response api-routes req)]
        [(and event-bus (sse-request? req)) (sse-response event-bus)]
        [(and serve-client? (api-client-request? req))
         (api-client-response api-routes)]
        [(directory-exists? public-dir) (serve-static-file public-dir req)]
        [else (make-404-response)]))
    (output-response conn resp)))

(define (sse-request? req)
  (and (bytes=? (request-method req) #"GET")
       (equal? (url-path-string (request-uri req)) sse-path)))

(define (api-client-request? req)
  (and (bytes=? (request-method req) #"GET")
       (equal? (url-path-string (request-uri req)) api-client-path)))

(define (url-path-string u)
  (string-join (map path/param-path (url-path u)) "/"))

;; ---- SSE endpoint ----

(define sse-keepalive-secs 15)

(define (sse-response bus)
  (define ch (bus-subscribe! bus))
  (response 200 #"OK" (current-seconds)
            #"text/event-stream"
            (list (header #"Cache-Control" #"no-cache"))
            (lambda (out)
              (dynamic-wind
                (lambda () (void))
                (lambda ()
                  (let loop ()
                    (define v (sync/timeout sse-keepalive-secs ch))
                    (cond
                      [(eq? v 'timeout)
                       (fprintf out ": keepalive\n\n")
                       (flush-output out)
                       (loop)]
                      [else
                       (match-define (list name data) v)
                       (fprintf out "event: ~a\ndata: ~a\n\n"
                                name (jsexpr->string data))
                       (flush-output out)
                       (loop)])))
                (lambda () (bus-unsubscribe! bus ch))))))

;; ---- generated JS client ----

;; Turns the registered routes into a small typed-by-construction client:
;;
;;   glaze.call(method, path, body)             — raw fetch wrapper
;;   glaze.api.counterBump(5)                   — one function per route,
;;                                                path params become arguments
;;   glaze.on('counter-changed', fn)            — EventSource subscription
;;                                                (only when #:events is live)
(define (api-client-response api-routes)
  (define js (generate-api-client api-routes))
  (response/full 200 #"OK" (current-seconds)
                 #"application/javascript; charset=utf-8" '()
                 (list (string->bytes/utf-8 js))))

(define (generate-api-client api-routes)
  (define entries
    (for/list ([r (in-list api-routes)])
      (define method (route-method r))
      (define segments (route-segments r))
      (define args
        (for/list ([seg (in-list segments)] #:when (param? seg))
          (param-id seg)))
      (define url-expr
        (string-join
         (for/list ([seg (in-list segments)])
           (if (param? seg)
               (string-append "'+encodeURIComponent(" (param-id seg) ")+'")
               seg))
         "/"))
      (define method-str (symbol->string method))
      (format "  ~a: function(~a) { return glaze.call('~a', '~a', ~a); },"
              (route->js-name segments)
              (string-join (append args '("body")) ", ")
              method-str
              url-expr
              (if (string=? method-str "GET") "null" "body"))))
  (string-append
   "/* Generated by glaze — do not edit. */\n"
   "window.glaze = window.glaze || {};\n"
   "glaze.call = async function(method, path, body) {\n"
   "  const opts = {method: method};\n"
   "  if (body !== null && body !== undefined) {\n"
   "    opts.headers = {'Content-Type': 'application/json'};\n"
   "    opts.body = JSON.stringify(body);\n"
   "  }\n"
   "  const r = await fetch('/' + path, opts);\n"
   "  if (!r.ok) { const t = await r.text(); throw new Error(t); }\n"
   "  const text = await r.text();\n"
   "  return text ? JSON.parse(text) : null;\n"
   "};\n"
   "glaze.on = function(name, fn) {\n"
   "  if (!glaze._es) glaze._es = new EventSource('/" sse-path "');\n"
   "  glaze._es.addEventListener(name, e => fn(JSON.parse(e.data), e));\n"
   "  return glaze._es;\n"
   "};\n"
   "glaze.api = {\n"
   (string-join entries "\n")
   "\n};\n"))

;; "api/counter/bump" -> counterBump ; "api/items/:id/bump" -> itemsIdBump
;; The first segment keeps its case (api/bump -> bump, not Bump).
(define (route->js-name segments)
  (define drop-api
    (if (and (pair? segments) (string=? (first segments) "api"))
        (rest segments)
        segments))
  (apply string-append
         (for/list ([seg (in-list drop-api)] [i (in-naturals)])
           (cond
             [(param? seg) (string-titlecase (param-id seg))]
             [(and (positive? i) (regexp-match? #rx"^[a-z]" seg))
              (string-append (string-upcase (substring seg 0 1)) (substring seg 1))]
             [else (if (param? seg) (param-id seg) seg)]))))

;; Try each route against the request; on a match apply the handler and
;; normalize its result (jsexpr -> 200 JSON; response -> itself; exception ->
;; 500 JSON). No match -> #f (fall through to static).
(define (find-api-response api-routes req)
  (define method
    (string->symbol (string-upcase (bytes->string/latin-1 (request-method req)))))
  (define segments
    (filter (lambda (s) (not (equal? s "")))
            (map path/param-path (url-path (request-uri req)))))
  (for/or ([r (in-list api-routes)])
    (define captured (route-match r method segments))
    (and captured
         (with-handlers ([exn:fail:glaze:bad-param?
                          (lambda (e) (error-response 400 (exn-message e)))]
                         [exn:fail? (lambda (e)
                                      (error-response 500 (exn-message e)))])
           (define result (apply (route-handler r) req captured))
           (cond
             [(response? result) result]
             [else (api-response result)])))))

(define (serve-static-file dir req)
  (define uri-path (url-path (request-uri req)))
  (define segments (filter (lambda (s) (not (equal? s ""))) (map path/param-path uri-path)))
  (define rel
    (if (null? segments)
        '("index.html")
        segments))
  (define candidate (apply build-path dir rel))
  (cond
    [(and (file-exists? candidate) (not (directory-exists? candidate)))
     (make-file-response candidate)]
    [else
     (define fallback (build-path dir "index.html"))
     (if (file-exists? fallback)
         (make-file-response fallback)
         (make-404-response))]))

(define (make-file-response path)
  (define data (file->bytes path))
  (define mime (path->mime-type path))
  (response/full 200 #"OK" (current-seconds) mime '() (list data)))

(define (make-404-response)
  (response/full 404
                 #"Not Found"
                 (current-seconds)
                 #"text/plain; charset=utf-8"
                 '()
                 (list #"Not found")))

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
