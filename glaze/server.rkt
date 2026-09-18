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
         "assets.rkt"
         "events.rkt")

(provide start-dev-server
         start-server
         stop-server
         path->mime-type
         current-glaze-error-reporter)

;; Exception reporter for API-handler failures (the 500 path). Default logs
;; to stderr; run-app parameterizes this to its #:on-error callback.
(define current-glaze-error-reporter
  (make-parameter
   (lambda (exn uri)
     (fprintf (current-error-port)
              "[glaze] handler error on ~a: ~a\n"
              uri (exn-message exn)))))

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
                      #:api-token [api-token #f]
                      #:serve-api-client? [serve-client? #t])
  (unless (and (exact-integer? port) (<= 1 port 65535))
    (raise-argument-error 'start-server "exact-integer? in [1, 65535]" port))
  (unless (or (path? public-dir) (string? public-dir))
    (raise-argument-error 'start-server "(or/c path? string?)" public-dir))
  (unless (and (list? api-routes) (andmap route? api-routes))
    (raise-argument-error 'start-server "(listof route?)" api-routes))
  (when (and event-bus (not (event-bus? event-bus)))
    (raise-argument-error 'start-server "(or/c #f event-bus?)" event-bus))
  (when (and api-token (not (string? api-token)))
    (raise-argument-error 'start-server "(or/c #f string?)" api-token))
  (unless (boolean? serve-client?)
    (raise-argument-error 'start-server "boolean?" serve-client?))
  (define resolved-public-dir (resolve-public-dir public-dir))
  (define dispatcher
    (make-dispatcher resolved-public-dir api-routes port event-bus serve-client? api-token))
  (define shutdown-server
    (serve #:dispatch dispatcher #:port port #:listen-ip "127.0.0.1"))
  ;; `serve` accepts the port synchronously but the accepting loop runs in a
  ;; background thread; if that thread dies (e.g. bind race), callers saw
  ;; only "connection refused" much later. Prove the listener is accepting
  ;; before returning — fail loudly, and never hand back a dead server.
  (wait-accepting! port shutdown-server)
  (values port shutdown-server))

(define (stop-server shutdown-proc)
  (shutdown-proc))

;; Backward-compatible alias. Prefer `start-server` in new code.
(define start-dev-server start-server)

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

(define (string-index-of s ch)
  (for/or ([c (in-string s)] [i (in-naturals)] #:when (char=? c ch)) i))

;; Parse a Host header without confusing the colons inside a bracketed IPv6
;; literal with the optional :port separator. Hostnames are case-insensitive.
(define (host-string-allowed? host)
  (define s (string-downcase (string-trim host)))
  (define bare
    (cond
      ;; Be liberal for raw clients even though HTTP normally brackets IPv6.
      [(string=? s "::1") "::1"]
      [(regexp-match #px"^\\[([^\\]]+)\\](?::[0-9]+)?$" s)
       => (lambda (m) (second m))]
      [else
       (define colon (string-index-of s #\:))
       (if colon (substring s 0 colon) s)]))
  (and (member bare '("127.0.0.1" "localhost" "::1")) #t))

(define (host-allowed? req _port)
  (define h (headers-assq #"Host" (request-headers/raw req)))
  (cond
    ;; No Host header (ancient clients, raw sockets): browsers always send one,
    ;; so this does not weaken the DNS-rebinding boundary for web content.
    [(not h) #t]
    [else
     (host-string-allowed? (bytes->string/latin-1 (header-value h)))]))

;; ---- dispatcher ----

(define (make-dispatcher public-dir api-routes port event-bus serve-client? api-token)
  (lambda (conn req)
    (define resp
      (cond
        [(not (host-allowed? req port)) (error-response 403 "host not allowed")]
        ;; One-time bootstrap: the capability URL (?glaze-token=..., opened by
        ;; run-app) exchanges the token for an HttpOnly cookie and redirects
        ;; to the clean path. api.js no longer hands the token out, so a
        ;; casual local prober that can read openly-served endpoints still
        ;; cannot mint a cookie.
        [(and api-token (bootstrap-request? req api-token))
         (bootstrap-response req)]
        ;; The token guards capabilities (API routes + the event stream),
        ;; not resources: static files and the api.js bootstrap stay open —
        ;; the page received its cookie via the bootstrap redirect above.
        [(and api-token (pair? api-routes) (not (token-ok? req api-token))
              (or (api-matches? api-routes req)
                  (and event-bus (sse-request? req))))
         (error-response 401 "missing or invalid glaze token")]
        [(find-api-response api-routes req)]
        [(and event-bus (sse-request? req)) (sse-response event-bus)]
        [(and serve-client? (api-client-request? req))
         (api-client-response api-routes api-token)]
        [(directory-exists? public-dir) (serve-static-file public-dir req)]
        [else (make-404-response)]))
    (output-response conn resp)))

;; Does any route match this request (method + path shape)?
(define (api-matches? api-routes req)
  (define method
    (string->symbol (string-upcase (bytes->string/latin-1 (request-method req)))))
  (define segments
    (filter (lambda (s) (not (equal? s "")))
            (map path/param-path (url-path (request-uri req)))))
  (for/or ([r (in-list api-routes)])
    (and (route-match r method segments) #t)))

;; Token arrives as the X-Glaze-Token header (curl / programmatic clients)
;; or the glaze_token cookie (browsers — EventSource cannot set headers, but
;; same-origin requests carry cookies, so SSE works unmodified).
(define (token-ok? req expected)
  (define h (headers-assq #"X-Glaze-Token" (request-headers/raw req)))
  (or (and h (string=? (bytes->string/latin-1 (header-value h)) expected))
      (let* ([cookie-h (headers-assq #"Cookie" (request-headers/raw req))]
             [cookie-str (and cookie-h
                              (bytes->string/latin-1 (header-value cookie-h)))])
        (and cookie-str
             (for/or ([part (in-list (string-split cookie-str ";"))])
               (define kv (string-split (string-trim part) "="))
               (and (= (length kv) 2)
                    (string=? (first kv) "glaze_token")
                    (string=? (second kv) expected)))))))

;; ---- token bootstrap (capability URL -> HttpOnly cookie) ----

(define bootstrap-param 'glaze-token)

(define (bootstrap-request? req expected)
  (for/or ([kv (in-list (url-query (request-uri req)))])
    (and (eq? (car kv) bootstrap-param)
         (string? (cdr kv))
         (string=? (cdr kv) expected))))

;; 302 back to the same path (query dropped), setting the cookie the page
;; will use for API + SSE calls. A wrong token in the query never matches
;; and falls through to the normal flow — no cookie is minted.
(define (bootstrap-response req)
  (define target
    (string-append "/" (url-path-string (request-uri req))))
  (define token
    (for/or ([kv (in-list (url-query (request-uri req)))]
             #:when (eq? (car kv) bootstrap-param))
      (cdr kv)))
  (response/full 302 #"Found" (current-seconds)
                 #"text/plain; charset=utf-8"
                 (list (header #"Location" (string->bytes/latin-1 target))
                       (header #"Set-Cookie"
                               (string->bytes/latin-1
                                (format "glaze_token=~a; Path=/; HttpOnly; SameSite=Strict"
                                        token))))
                 (list (string->bytes/utf-8 (format "Redirecting to ~a\n" target)))))

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
(define (api-client-response api-routes [api-token #f])
  ;; api-token is accepted for signature compatibility but deliberately NOT
  ;; served here: this endpoint is openly readable, and embedding the token
  ;; (or setting the cookie) in the response would let any local prober
  ;; mint credentials. The page gets its cookie via the ?glaze-token=
  ;; bootstrap redirect instead (run-app opens that URL automatically).
  (define js (generate-api-client api-routes))
  (response/full 200 #"OK" (current-seconds)
                 #"application/javascript; charset=utf-8"
                 '()
                 (list (string->bytes/utf-8 js))))

(define (generate-api-client api-routes)
  (define entries
    (for/list ([r (in-list api-routes)])
      (define method-str (symbol->string (route-method r)))
      (define segments (route-segments r))
      ;; Generated JavaScript uses positional internal parameter names rather
      ;; than route parameter text. A route like :user-id must not produce an
      ;; illegal JS identifier such as `function(user-id, ...)`.
      (define param-count
        (for/sum ([seg (in-list segments)]) (if (param? seg) 1 0)))
      (define args
        (append (for/list ([i (in-range param-count)]) (format "p~a" i))
                '("body")))
      (define next-param 0)
      (define url-pieces
        (for/list ([seg (in-list segments)])
          (cond
            [(param? seg)
             (define i next-param)
             (set! next-param (add1 next-param))
             (format "encodeURIComponent(p~a)" i)]
            [else
             ;; jsexpr->string gives us a correctly escaped JS string literal.
             (jsexpr->string seg)])))
      (define url-expr
        (if (null? url-pieces)
            "\"\""
            (string-join url-pieces " + '/' + ")))
      (format "  ~a: function(~a) { return glaze.call(~a, ~a, ~a); },"
              (jsexpr->string (route->js-name segments))
              (string-join args ", ")
              (jsexpr->string method-str)
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
;; "api/clip-copy" -> clipCopy. Hyphenated segments camel-case (a bare
;; hyphen key like `clip-copy:` would be ILLEGAL JavaScript and break the
;; whole generated file); the first segment keeps a lowercase head.
(define (js-camel seg first-lower?)
  (define parts (filter non-empty-string? (string-split seg "-")))
  (apply string-append
         (for/list ([p (in-list parts)] [i (in-naturals)])
           (if (and (zero? i) first-lower? (regexp-match? #rx"^[a-z]" p))
               p
               (string-append (string-upcase (substring p 0 1)) (substring p 1))))))

(define (route->js-name segments)
  (define drop-api
    (if (and (pair? segments) (string=? (first segments) "api"))
        (rest segments)
        segments))
  (apply string-append
         (for/list ([seg (in-list drop-api)] [i (in-naturals)])
           (cond
             [(param? seg) (js-camel (param-id seg) #f)]
             [(zero? i) (js-camel seg #t)]
             [else (js-camel seg #f)]))))

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
                         [exn:fail?
                          (lambda (e)
                            ;; Preserve diagnostic detail for the trusted
                            ;; reporter, but never expose arbitrary exception
                            ;; text to the WebView/browser response.
                            ((current-glaze-error-reporter)
                             e
                             (url-path-string (request-uri req)))
                            (error-response 500 "internal server error"))])
           (define result (apply (route-handler r) req captured))
           (cond
             [(response? result) result]
             [else (api-response result)])))))

;; Return #t when candidate is at or below root after path normalization.
;; `find-relative-path` also handles Windows drive boundaries for us.
(define (path-contained? root candidate)
  (define rel (find-relative-path root candidate))
  (and (relative-path? rel)
       (for/and ([part (in-list (explode-path rel))])
         (not (eq? part 'up)))))

;; Build a request path below public-dir and prove it cannot escape. Existing
;; files are normalized through the filesystem as a second check so a symlink
;; inside public/ cannot expose a file outside the public root.
(define (safe-public-candidate dir segments)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define root (simplify-path (path->complete-path dir) #t))
    (define candidate
      (simplify-path (apply build-path root segments) #f))
    (and (path-contained? root candidate)
         (cond
           [(file-exists? candidate)
            (define resolved (simplify-path candidate #t))
            (and (path-contained? root resolved) resolved)]
           [else candidate]))))

(define (serve-static-file dir req)
  (define uri-path (url-path (request-uri req)))
  (define segments
    (filter (lambda (s) (not (equal? s "")))
            (map path/param-path uri-path)))
  (define rel
    (if (null? segments)
        '("index.html")
        segments))
  (define candidate (safe-public-candidate dir rel))
  (cond
    [(not candidate)
     (error-response 403 "path not allowed")]
    [(and (file-exists? candidate) (not (directory-exists? candidate)))
     (make-file-response candidate)]
    [else
     (define fallback (safe-public-candidate dir '("index.html")))
     (if (and fallback (file-exists? fallback))
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

(module+ test-support
  (provide host-string-allowed?
           safe-public-candidate))
