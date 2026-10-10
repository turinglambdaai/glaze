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
         "capability.rkt"
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
     (fprintf (current-error-port) "[glaze] handler error on ~a: ~a\n" uri (exn-message exn)))))

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
                      #:capability [authority #f]
                      #:serve-api-client? [serve-client? #t]
                      #:max-body-size [max-body-size default-max-body-size])
  (when (and event-bus (not (event-bus? event-bus)))
    (raise-argument-error 'start-server "event-bus?" event-bus))
  (when (and api-token (not (string? api-token)))
    (raise-argument-error 'start-server "(or/c #f string?)" api-token))
  (when (and authority (not (capability? authority)))
    (raise-argument-error 'start-server "(or/c #f capability?)" authority))
  (when (and authority (not (and (string? api-token) (not (string=? api-token "")))))
    (raise-arguments-error
     'start-server
     "a capability requires a non-empty #:api-token so authority stays bound to the WebView"
     "capability"
     (capability-id authority)))
  (unless (exact-nonnegative-integer? max-body-size)
    (raise-argument-error 'start-server "exact-nonnegative-integer?" max-body-size))
  ;; Fail at startup, not at first request: a route that cannot be expressed
  ;; in the generated client is a configuration bug.
  (when serve-client? (validate-js-client-names api-routes))
  (define dispatcher
    (make-dispatcher public-dir api-routes port event-bus serve-client? api-token authority max-body-size))
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
        [else
         (sleep 0.02)
         (loop)])))
  (unless accepting?
    (shutdown-server)
    (raise-arguments-error
     'start-server
     (format "listener on port ~a did not start accepting within ~as" port listen-wait-secs)
     "port"
     port)))

;; ---- Host-header validation (DNS-rebinding guard) ----

(define (host-allowed? req port)
  (define h (headers-assq #"Host" (request-headers/raw req)))
  (cond
    ;; No Host header (ancient clients, raw sockets): nothing was spoofed.
    [(not h) #t]
    [else
     (define host (bytes->string/latin-1 (header-value h)))
     (define bare
       (if (string-contains? host ":")
           (substring host 0 (string-index-of host #\:))
           host))
     (member bare (list "127.0.0.1" "localhost" "[::1]" "::1"))]))

(define (string-index-of s ch)
  (for/or ([c (in-string s)]
           [i (in-naturals)]
           #:when (char=? c ch))
    i))

;; ---- dispatcher ----

;; Local apps are reachable by every website in every browser. The Host check
;; above stops DNS rebinding; this limit caps how much a single request can
;; make the server buffer. 8 MiB covers JSON API payloads with headroom.
(define default-max-body-size (* 8 1024 1024))

(define (body-too-large? req limit)
  (define h (headers-assq #"Content-Length" (request-headers/raw req)))
  (cond
    [(not h) #f]
    [else
     (define v (string->number (string-trim (bytes->string/latin-1 (header-value h)))))
     (and v (exact-positive-integer? v) (> v limit))]))

;; Fetch-Metadata + Origin guard for the bridge surface (API routes + SSE).
;; A cross-site page posting to a loopback API (`content-type: text/plain`
;; simple request, no preflight) cannot be stopped by the browser's read
;; rules — the request itself is the side effect. Browsers tag such requests
;; with a foreign Origin and/or Sec-Fetch-Site: cross-site; curl and plain
;; programmatic clients send neither header and are unaffected. Same-origin
;; is decided against every loopback spelling of this server's port, because
;; an app may be opened at localhost instead of 127.0.0.1.
(define (bridge-request? matched-api events-request?)
  (or matched-api events-request?))

(define (cross-site-request? req port)
  (define origin-h (headers-assq #"Origin" (request-headers/raw req)))
  (define fetch-site-h (headers-assq #"Sec-Fetch-Site" (request-headers/raw req)))
  (cond
    [origin-h
     (with-handlers ([exn:fail? (lambda (_) #t)])
       (define u (string->url (bytes->string/latin-1 (header-value origin-h))))
       (not (and (equal? (url-scheme u) "http")
                 (member (url-host u) '("127.0.0.1" "localhost" "::1"))
                 (let ([p (url-port u)])
                   (if p (= p port) (= port 80))))))]
    [fetch-site-h
     (not (member (bytes->string/latin-1 (header-value fetch-site-h)) '("same-origin" "none")))]
    [else #f]))

(define (make-dispatcher public-dir
                         api-routes
                         port
                         event-bus
                         serve-client?
                         api-token
                         authority
                         max-body-size)
  (lambda (conn req)
    (define matched-api (find-api-match api-routes req))
    (define events-request? (and event-bus (sse-request? req)))
    (define resp
      (cond
        [(not (host-allowed? req port)) (error-response 403 "host not allowed")]
        [(body-too-large? req max-body-size) (error-response 413 "request body too large")]
        [(and (bridge-request? matched-api events-request?) (cross-site-request? req port))
         (error-response 403 "cross-origin request rejected")]
        ;; One-time bootstrap: the capability URL (?glaze-token=..., opened by
        ;; run-app) exchanges the token for an HttpOnly cookie and redirects
        ;; to the clean path. api.js no longer hands the token out, so a
        ;; casual local prober that can read openly-served endpoints still
        ;; cannot mint a cookie.
        [(and api-token (bootstrap-request? req api-token)) (bootstrap-response req)]
        ;; The token guards capabilities (API routes + the event stream),
        ;; not resources: static files and the api.js bootstrap stay open —
        ;; the page received its cookie via the bootstrap redirect above.
        [(and api-token (not (token-ok? req api-token)) (or matched-api events-request?))
         (error-response 401 "missing or invalid glaze token")]
        [(and matched-api authority (not (api-match-authorized? authority matched-api req)))
         (error-response 403 "capability denied API route")]
        [matched-api (api-match-response matched-api req authority)]
        [(and events-request? authority (not (capability-authorized? authority 'glaze:events)))
         (error-response 403 "capability denied event stream")]
        [events-request? (sse-response event-bus)]
        [(and serve-client? (api-client-request? req))
         (api-client-response api-routes api-token authority)]
        [(directory-exists? public-dir) (serve-static-file public-dir req)]
        [else (make-404-response)]))
    (output-response conn resp)))

;; Token arrives as the X-Glaze-Token header (curl / programmatic clients)
;; or the glaze_token cookie (browsers — EventSource cannot set headers, but
;; same-origin requests carry cookies, so SSE works unmodified).
(define (token-ok? req expected)
  (define h (headers-assq #"X-Glaze-Token" (request-headers/raw req)))
  (or (and h (string=? (bytes->string/latin-1 (header-value h)) expected))
      (let* ([cookie-h (headers-assq #"Cookie" (request-headers/raw req))]
             [cookie-str (and cookie-h (bytes->string/latin-1 (header-value cookie-h)))])
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
    (and (eq? (car kv) bootstrap-param) (string? (cdr kv)) (string=? (cdr kv) expected))))

;; 302 back to the same path (query dropped), setting the cookie the page
;; will use for API + SSE calls. A wrong token in the query never matches
;; and falls through to the normal flow — no cookie is minted.
(define (bootstrap-response req)
  (define target (string-append "/" (url-path-string (request-uri req))))
  (define token
    (for/or ([kv (in-list (url-query (request-uri req)))]
             #:when (eq? (car kv) bootstrap-param))
      (cdr kv)))
  (response/full 302
                 #"Found"
                 (current-seconds)
                 #"text/plain; charset=utf-8"
                 (list (header #"Location" (string->bytes/latin-1 target))
                       (header #"Set-Cookie"
                               (string->bytes/latin-1
                                (format "glaze_token=~a; Path=/; HttpOnly; SameSite=Strict" token))))
                 (list (string->bytes/utf-8 (format "Redirecting to ~a\n" target)))))

(define (sse-request? req)
  (and (bytes=? (request-method req) #"GET") (equal? (url-path-string (request-uri req)) sse-path)))

(define (api-client-request? req)
  (and (bytes=? (request-method req) #"GET")
       (equal? (url-path-string (request-uri req)) api-client-path)))

;; url-path-string is called on every request before the static-file guard,
;; so a raw "../" in the request line (parsed as path/param 'up symbols)
;; must not blow up string-join's contract — render such segments verbatim;
;; they simply never match the /glaze/* paths and fall through to the static
;; handler, which rejects them.
(define (url-path-string u)
  (string-join
   (for/list ([p (in-list (url-path u))])
     (define seg (path/param-path p))
     (if (string? seg) seg (format "~a" seg)))
   "/"))

;; ---- SSE endpoint ----

(define sse-keepalive-secs 15)

(define (sse-response bus)
  (define ch (bus-subscribe! bus))
  (response 200
            #"OK"
            (current-seconds)
            #"text/event-stream"
            (list (header #"Cache-Control" #"no-cache"))
            (lambda (out)
              (dynamic-wind (lambda () (void))
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
                                   (fprintf out "event: ~a\ndata: ~a\n\n" name (jsexpr->string data))
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
(define (api-client-response api-routes [api-token #f] [authority #f])
  ;; api-token is accepted for signature compatibility but deliberately NOT
  ;; served here: this endpoint is openly readable, and embedding the token
  ;; (or setting the cookie) in the response would let any local prober
  ;; mint credentials. The page gets its cookie via the ?glaze-token=
  ;; bootstrap redirect instead (run-app opens that URL automatically).
  (define visible-routes
    (if authority
        (filter (lambda (route)
                  (and (route-permission route)
                       (capability-has-permission? authority (route-permission route))))
                api-routes)
        api-routes))
  (define js (generate-api-client visible-routes))
  (response/full 200
                 #"OK"
                 (current-seconds)
                 #"application/javascript; charset=utf-8"
                 '()
                 (list (string->bytes/utf-8 js))))

(define (generate-api-client api-routes)
  ;; Group routes by their generated JS name. One name + one method is the
  ;; plain single entry; one name + several methods (GET/POST on the same
  ;; path) becomes a single dispatching function that sends the GET when
  ;; called without a body and the first non-GET route otherwise. Groups are
  ;; kept in first-seen order so the generated file is deterministic.
  (define names '())
  (define groups (make-hash))
  (for ([r (in-list api-routes)])
    (define name (route->js-name (route-segments r)))
    (unless (member name names)
      (set! names (append names (list name))))
    (hash-update! groups name (lambda (old) (append old (list r))) '()))
  (define entries
    (for/list ([name (in-list names)])
      (define group (hash-ref groups name))
      (if (= (length group) 1)
          (route-js-entry name (first group))
          (merged-route-js-entry name group))))
  (string-append "/* Generated by glaze — do not edit. */\n"
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
                 "  if (!glaze._es) glaze._es = new EventSource('/"
                 sse-path
                 "');\n"
                 "  glaze._es.addEventListener(name, e => fn(JSON.parse(e.data), e));\n"
                 "  return glaze._es;\n"
                 "};\n"
                 "glaze.api = {\n"
                 (string-join entries "\n")
                 "\n};\n"))

;; The path arguments a route's JS entry takes (the captured :params), and
;; the URL expression that interpolates them.
(define (route-js-args segments)
  (for/list ([seg (in-list segments)]
             #:when (param? seg))
    (param-id seg)))

(define (route-js-url segments)
  (string-join
   (for/list ([seg (in-list segments)])
     (if (param? seg)
         (string-append "'+encodeURIComponent(" (param-id seg) ")+'")
         seg))
   "/"))

(define (route-js-call route)
  (define method-str (symbol->string (route-method route)))
  (format "glaze.call('~a', '~a', ~a)"
          method-str
          (route-js-url (route-segments route))
          (if (string=? method-str "GET") "null" "body")))

(define (route-js-entry name route)
  (define args (append (route-js-args (route-segments route)) '("body")))
  (format "  ~a: function(~a) { return ~a; },"
          name
          (string-join args ", ")
          (route-js-call route)))

;; GET /api/items + POST /api/items -> items(id, body): a missing body means
;; the GET; anything else goes to the first non-GET route (validated at
;; startup to exist and to be unique).
(define (merged-route-js-entry name group)
  (define get-route (findf (lambda (r) (eq? (route-method r) 'GET)) group))
  (define mutating (findf (lambda (r) (not (eq? (route-method r) 'GET))) group))
  (define segments (route-segments (or get-route mutating)))
  (define args (append (route-js-args segments) '("body")))
  (string-append
   "  " name ": function(" (string-join args ", ") ") {\n"
   (if get-route
       (format "    if (body === undefined || body === null) { return ~a; }\n"
               (route-js-call get-route))
       "")
   (if mutating
       (format "    return ~a;\n" (route-js-call mutating))
       "")
   "  },"))

;; "api/counter/bump" -> counterBump ; "api/items/:id/bump" -> itemsIdBump
;; "api/clip-copy" -> clipCopy. Hyphenated segments camel-case (a bare
;; hyphen key like `clip-copy:` would be ILLEGAL JavaScript and break the
;; whole generated file); the first segment keeps a lowercase head. Every
;; part is stripped to identifier characters, and a name that would start
;; with a digit is prefixed with "_" — both keep the generated file parseable
;; for any route shape; validate-js-client-names rejects what still cannot
;; work (empty names, collisions).
(define (js-camel seg first-lower?)
  (define parts
    (for/list ([p (in-list (filter non-empty-string? (string-split seg "-")))])
      (regexp-replace* #rx"[^A-Za-z0-9_]" p "")))
  (define kept (filter non-empty-string? parts))
  (if (null? kept)
      ""
      (apply string-append
             (for/list ([p (in-list kept)]
                        [i (in-naturals)])
               (cond
                 [(and (zero? i) first-lower? (regexp-match? #rx"^[a-z]" p)) p]
                 [else (string-append (string-upcase (substring p 0 1)) (substring p 1))])))))

(define (route->js-name segments)
  (define drop-api
    (if (and (pair? segments) (string=? (first segments) "api"))
        (rest segments)
        segments))
  (define raw
    (apply string-append
           (for/list ([seg (in-list drop-api)]
                      [i (in-naturals)])
             (cond
               [(param? seg) (string-titlecase (param-id seg))]
               [(zero? i) (js-camel seg #t)]
               [else (js-camel seg #f)]))))
  (if (regexp-match? #rx"^[0-9]" raw)
      (string-append "_" raw)
      raw))

(define (route-descriptor r)
  (format "~a /~a"
          (route-method r)
          (string-join
           (for/list ([seg (in-list (route-segments r))])
             (if (param? seg) (string-append ":" (param-id seg)) seg))
           "/")))

;; The generated api.js turns each route into a JS function name. Validation
;; runs at startup so misconfiguration fails loudly, not as a silently
;; corrupted client:
;;   - the same JS name with the same HTTP method twice is a genuine
;;     collision (later object keys would overwrite earlier ones);
;;   - the same name with DIFFERENT methods is legal REST (GET + POST on one
;;     path) — the client merges them into one dispatching function, and
;;     that merge needs a GET to answer body-less calls;
;;   - whatever remains must be a valid JavaScript identifier.
(define (validate-js-client-names routes)
  (define by-name (make-hash))
  (for ([r (in-list routes)])
    (define name (route->js-name (route-segments r)))
    (unless (regexp-match? #px"^[A-Za-z_$][A-Za-z0-9_$]*$" name)
      (raise-arguments-error 'start-server
                             "route produces an invalid JavaScript identifier"
                             "route"
                             (route-descriptor r)
                             "js name"
                             (if (zero? (string-length name)) "(empty)" name)))
    (hash-update! by-name name (lambda (old) (append old (list r))) '()))
  (for ([(name group) (in-hash by-name)])
    (define duplicate-method
      (check-duplicates (map route-method group) eq?))
    (when duplicate-method
      (define same-method
        (filter (lambda (r) (eq? (route-method r) duplicate-method)) group))
      (raise-arguments-error 'start-server
                             "two routes with the same method map to the same JavaScript function name"
                             "js name"
                             name
                             "first route"
                             (route-descriptor (first same-method))
                             "second route"
                             (route-descriptor (second same-method))))
    (when (> (length group) 1)
      (unless (member 'GET (map route-method group))
        (raise-arguments-error 'start-server
                               "routes sharing a JavaScript name need a GET route for body-less calls"
                               "js name"
                               name
                               "routes"
                               (string-join (map route-descriptor group) ", "))))))

;; Match once so token and capability checks apply to exactly the route whose
;; handler will run.
(define (find-api-match api-routes req)
  (define method (string->symbol (string-upcase (bytes->string/latin-1 (request-method req)))))
  (define segments
    (filter (lambda (s) (not (equal? s ""))) (map path/param-path (url-path (request-uri req)))))
  (for/or ([r (in-list api-routes)])
    (define captured (route-match r method segments))
    (and captured (list r captured))))

(define (api-match-authorized? authority matched req)
  (define route (first matched))
  (define captured (second matched))
  (define permission (route-permission route))
  (and permission
       (capability-has-permission? authority permission)
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (define resource-proc (route-resource route))
         (define resource
           (and resource-proc
                (parameterize ([current-capability-id (capability-id authority)]
                               [current-capability-authorizer
                                (lambda (permission resource)
                                  (capability-authorized? authority permission resource))])
                  (apply resource-proc req captured))))
         (capability-authorized? authority permission resource))))

(define (api-match-response matched req [authority #f])
  (define route (first matched))
  (define captured (second matched))
  (with-handlers ([exn:fail:glaze:bad-param? (lambda (e) (error-response 400 (exn-message e)))]
                  ;; Internal failures never echo exception text to the page —
                  ;; messages leak implementation detail (paths, SQL, stack
                  ;; frames). The full exn goes to the error reporter; the
                  ;; client gets a stable, generic 500 body.
                  [exn:fail? (lambda (e)
                               ((current-glaze-error-reporter) e (url-path-string (request-uri req)))
                               (error-response 500 "internal error"))])
    (define result
      (parameterize ([current-capability-id (and authority (capability-id authority))]
                     [current-capability-authorizer
                      (and authority
                           (lambda (permission resource)
                             (capability-authorized? authority permission resource)))])
        (apply (route-handler route) req captured)))
    (cond
      [(response? result) result]
      [else (api-response result)])))

(define (serve-static-file dir req)
  (define uri-path (url-path (request-uri req)))
  (define segments (filter (lambda (s) (not (equal? s ""))) (map path/param-path uri-path)))
  (define rel
    (if (null? segments)
        '("index.html")
        segments))
  (cond
    ;; ".." and "." arrive as path/param 'up / 'same symbols. Feeding them to
    ;; build-path walks outside public-dir (an arbitrary file read via
    ;; %2e%2e) or crashes the connection thread on the raw 'up contract — so
    ;; anything that is not a plain string never touches the filesystem.
    [(not (andmap string? rel)) (make-404-response)]
    [else
     (define candidate (apply build-path dir rel))
     (cond
       [(and (file-exists? candidate)
             (not (directory-exists? candidate))
             (static-file-contained? dir candidate))
        (make-file-response candidate)]
       [else
        (define fallback (build-path dir "index.html"))
        (if (and (file-exists? fallback) (static-file-contained? dir fallback))
            (make-file-response fallback)
            (make-404-response))])]))

;; Filesystem-level containment behind the lexical guard above: a symlink
;; inside public-dir must not smuggle a path outside it. Both sides resolve
;; every symlink component first (e.g. /tmp -> /private/tmp on macOS), so the
;; prefix check compares real locations, not spellings.
(define (static-file-contained? root candidate)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (path-inside? (canonical-path root) (canonical-path candidate))))

(define (make-file-response path)
  (define data (file->bytes path))
  (define mime (path->mime-type path))
  (response/full 200
                 #"OK"
                 (current-seconds)
                 mime
                 (list (header #"X-Content-Type-Options" #"nosniff"))
                 (list data)))

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
