#lang racket/base

;; Cross-platform WebView conformance suite (G4-S1). Exits 0 on success,
;; 1 on failure — designed for CI (runs on a real desktop session on all
;; three OSes; on Linux run under xvfb-run).
;;
;; Scenario coverage maps one-to-one onto the G4 conformance matrix
;; (docs/1.0-plan.md):
;;
;;   open, resource load   — HTTP window: open -> first page loads (title
;;                           commits) -> scheme/HTTP resources served
;;   capture               — composited page pixels in the PNG
;;   close                 — webview-close -> on-close -> closed? ->
;;                           window state persisted
;;   navigation policy     — the loopback HTTP adapter refuses foreign
;;                           Host headers (403) and serves loopback ones;
;;                           the native page runs on the controlled origin
;;   native transport      — open, controlled-origin load, hello, ping
;;                           round trip
;;   typed invoke          — typed route (GString param): valid invoke
;;                           returns the value, invalid invoke is rejected
;;                           with code invalid-args
;;   stream                — invokeStream delivers ordered chunks via
;;                           onDelta and the full text on the terminal
;;                           frame
;;   cancel                — an AbortSignal rejects the invoke at once and
;;                           closes the stream pipe server side (the
;;                           writer observes the close)
;;   events                — event-bus broadcasts arrive through
;;                           __glz1Events in broadcast order
;;   per-window denial     — a window opened with a restricted capability
;;                           gets capability-denied on a protected route
;;                           while the full-authority window passes
;;   deterministic teardown— shutdown! returns promptly, is idempotent,
;;                           and freezes the stats
;;
;;   racket scripts/webview-e2e.rkt          (macOS / Windows)
;;   xvfb-run -a racket scripts/webview-e2e.rkt   (Linux)

(require racket/file
         racket/list
         racket/string
         racket/tcp
         glaze/api
         glaze/api-macros
         glaze/app
         glaze/capability
         glaze/events
         glaze/native-transport
         glaze/server
         (only-in glaze/types GString)
         glaze/webview/main)

;; stderr logging so the run leaves evidence in CI logs.
(define (log msg)
  (fprintf (current-error-port) "[e2e] ~a\n" msg))

(define failures '())
(define (check! name ok?)
  (printf "[e2e] ~a ~a\n" (if ok? "PASS" "FAIL") name)
  (unless ok?
    (set! failures (cons name failures))))

(define (wait-until pred [secs 30])
  (define deadline (+ (current-inexact-milliseconds) (* secs 1000)))
  (let loop ()
    (cond
      [(pred) #t]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else
       (sleep 0.25)
       (loop)])))

;; ---- window: open, resource load, capture, close, navigation policy ----

(define dir (make-temporary-file "glaze-e2e-~a" 'directory))
(for ([page '("index.html" "p2.html")]
      [doc '(("<title>E2E loading</title>" "ONE") ("<title>E2E Two</title>" "TWO"))])
  (call-with-output-file
   (build-path dir page)
   (lambda (o)
     (if (string=? page "index.html")
         (fprintf
          o
          (string-append
           "<html><head>~a</head><body style=\"margin:0;background:#C15F3C\">"
           "<canvas id=\"paint\" width=\"600\" height=\"400\"></canvas><script>"
           "const c=document.getElementById('paint'),x=c.getContext('2d'),"
           "d=x.createImageData(c.width,c.height);let s=305419896;"
           "for(let i=0;i<d.data.length;i+=4){s^=s<<13;s^=s>>>17;s^=s<<5;"
           "d.data[i]=s&255;d.data[i+1]=(s>>>8)&255;d.data[i+2]=(s>>>16)&255;d.data[i+3]=255;}"
           "x.putImageData(d,0,0);document.title='E2E One';</script></body></html>")
          (first doc))
         (fprintf
          o
          "<html><head>~a</head><body style=\"background:#C15F3C;color:#fff\"><h1>~a</h1></body></html>"
          (first doc)
          (second doc))))
   #:exists 'replace))

(define-values (port stop) (start-server #:port 18970 #:public-dir dir))
(printf "[e2e] server up on ~a, backend-supported?=~a\n" port (webview-supported?))

(define closed? (box #f))
(define state-path (make-temporary-file "glaze-window-state-e2e-~a.json"))
(define wv
  (open-window (format "http://127.0.0.1:~a/" port)
               #:title "glaze e2e"
               #:width 640
               #:height 480
               #:window-state state-path
               #:on-close (lambda () (set-box! closed? #t))))
(check! "open: open-window returns webview" (webview? wv))
(unless (webview? wv)
  (printf "[e2e] backend unavailable on this host — FAIL\n")
  (exit 1))

(define title1-ok? (wait-until (lambda () (equal? (webview-title wv) "E2E One"))))
(unless title1-ok?
  (log (format "timeout: title=~s url=~s" (webview-title wv) (webview-url wv))))
(check! "resource load: page 1 title commits" title1-ok?)
(check! "resource load: page 1 url" (equal? (webview-url wv) (format "http://127.0.0.1:~a/" port)))

(define geometry-ready? (wait-until (lambda () (webview-window-state wv)) 10))
(check! "window geometry is observable" geometry-ready?)
(check! "virtual desktop is observable" (screen-area? (webview-screen-area)))
(when geometry-ready?
  (define current (webview-window-state wv))
  (webview-set-window-state!
   wv
   (window-state (window-state-x current) (window-state-y current) 620 460 #f))
  (check! "window geometry is mutable"
          (wait-until (lambda ()
                        (define changed (webview-window-state wv))
                        (and changed
                             (>= (window-state-width changed) 600)
                             (>= (window-state-height changed) 440)))
                      10)))

;; The first page paints deterministic high-entropy pixels into a canvas. A
;; title can commit while macOS still shows a white, uncomposited remote layer;
;; requiring a large PNG makes that failure visible to CI.
(define shot
  (let retry ([deadline (+ (current-inexact-milliseconds) 10000)])
    (define s (and (webview? wv) (webview-capture! wv)))
    (cond
      [(and s (file-exists? s) (>= (file-size s) 50000)) s]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else
       (sleep 0.3)
       (retry deadline)])))
(check! "capture: composited page pixels" (and shot #t))
(when shot
  (log (format "capture: ~a (~a bytes)" shot (file-size shot))))

(webview-navigate wv (format "http://127.0.0.1:~a/p2.html" port))
(define title2-ok? (wait-until (lambda () (equal? (webview-title wv) "E2E Two"))))
(unless title2-ok?
  (log (format "nav timeout: title=~s url=~s" (webview-title wv) (webview-url wv))))
(check! "navigate: page 2 title commits" title2-ok?)

;; Navigation/serving policy: the loopback HTTP adapter refuses foreign
;; Host headers and serves loopback ones. Probed with raw TCP so the
;; check observes exactly what a WebView navigation would hit.
(define (probe-host-status host)
  (define-values (in out) (tcp-connect "127.0.0.1" port))
  (fprintf out "GET / HTTP/1.1\r\nHost: ~a\r\nConnection: close\r\n\r\n" host)
  (flush-output out)
  (define line (read-line in 'return-linefeed))
  (close-input-port in)
  (close-output-port out)
  (and (string? line)
       (let ([m (regexp-match #px"^HTTP/1\\.[01] ([0-9]{3})" line)])
         (and m (string->number (second m))))))
(define foreign-status (probe-host-status "evil.example"))
(define loopback-status (probe-host-status (format "127.0.0.1:~a" port)))
(log (format "host probes: foreign=~s loopback=~s" foreign-status loopback-status))
(check! "navigation policy: foreign Host refused" (equal? foreign-status 403))
(check! "navigation policy: loopback Host served" (equal? loopback-status 200))

(webview-close wv)
(sleep 0.5)
(check! "close: on-close fired" (unbox closed?))
(check! "close: window state persisted" (window-state? (read-window-state state-path)))

(stop)
(delete-directory/files dir)
(when (file-exists? state-path)
  (delete-file state-path))

;; ---- native transport conformance: hello, typed invoke, stream, cancel,
;; ---- events, deterministic teardown ----
;; The page loads from glaze://app/ (never a TCP port) and runs the full
;; invoke battery through the host's message handler, reporting every step
;; back through api/conf-done. This proves the FULL loop per scenario:
;; bootstrap injected at document start, message reached the transport,
;; dispatch ran the route, and the response was delivered back into the
;; page's promise chain.
(define nt-dir (make-temporary-file "glaze-e2e-native-~a" 'directory))
(define nt-page
  (string-append
   "<!DOCTYPE html><html><head><title>native-e2e</title>"
   "<script src=\"/glaze/api.js\"></script></head><body>native</body>"
   "<script>"
   "var results = {};"
   "function rec(name, ok, detail) {"
   "  results[name] = { ok: ok === true, detail: detail === undefined ? null : detail };"
   "}"
   "var got = [];"
   "glaze.on('conf-evt', function (data) { got.push(data && data.n); });"
   "var chain = Promise.resolve();"
   "chain = chain.then(function () {"
   "  return glaze.hello().then(function (h) {"
   "    rec('hello', h && h.glz === 1 && Array.isArray(h.routes)"
   "      && h.routes.some(function (r) { return r.path === '/api/ping'; }));"
   "  });"
   "});"
   "chain = chain.then(function () {"
   "  return glaze.invoke('api/ping').then(function (v) { rec('ping', v && v.pong === true); });"
   "});"
   "chain = chain.then(function () {"
   "  return glaze.invoke('api/typed-echo', { word: 'ok' })"
   "    .then(function (v) { rec('typed-ok', v && v.word === 'ok'); });"
   "});"
   "chain = chain.then(function () {"
   "  return glaze.invoke('api/typed-echo', { word: 123 })"
   "    .then(function () { rec('typed-bad', false, 'resolved'); },"
   "          function (e) { rec('typed-bad', e && e.code === 'invalid-args', e && e.code); });"
   "});"
   "chain = chain.then(function () {"
   "  var batch = [];"
   "  for (var i = 0; i < 24; i++) {"
   "    batch.push(glaze.invoke('api/typed-echo', { word: 'burst-' + i }));"
   "  }"
   "  return Promise.all(batch).then(function (values) {"
   "    rec('burst', values.length === 24 && values.every(function (v, i) {"
   "      return v && v.word === 'burst-' + i;"
   "    }));"
   "  });"
   "});"
   "chain = chain.then(function () {"
   "  var deltas = [];"
   "  return glaze.invokeStream('api/stream', {},"
   "    { onDelta: function (t) { deltas.push(t); } })"
   "    .then(function (full) {"
   "      rec('stream', full === 'alpha-beta-gamma-' && deltas.length === 3,"
   "          deltas.join('|'));"
   "    });"
   "});"
   "chain = chain.then(function () {"
   "  var ctrl = new AbortController();"
   "  var p = glaze.invokeStream('api/slow', {}, { signal: ctrl.signal });"
   "  setTimeout(function () { ctrl.abort(); }, 400);"
   "  return p.then(function () { rec('cancel', false, 'resolved'); },"
   "                function (e) {"
   "                  rec('cancel', String(e).indexOf('aborted') >= 0, String(e));"
   "                });"
   "});"
   "chain = chain.then(function () {"
   "  return glaze.invoke('api/conf-ready').then(function () {"
   "    return new Promise(function (resolve) {"
   "      var tries = 0;"
   "      var iv = setInterval(function () {"
   "        tries++;"
   "        if (got.length >= 3 || tries > 100) {"
   "          clearInterval(iv);"
   "          rec('events', got.join(',') === '1,2,3', got.join(','));"
   "          resolve();"
   "        }"
   "      }, 100);"
   "    });"
   "  });"
   "});"
   "chain = chain.then(function () {"
   "  results.href = location.href;"
   "  return glaze.invoke('api/conf-done', results);"
   "});"
   "chain.catch(function (e) { window.__confError = String(e); });"
   "</script></html>"))
(call-with-output-file (build-path nt-dir "index.html")
                       (lambda (o) (display nt-page o))
                       #:exists 'replace)

(define conf-results (box #f))
(define conf-sema (make-semaphore 0))
(define slow-canceled (box #f))
(define conf-bus (make-event-bus))

(define-api-routes conf-typed
                   [(POST "api/typed-echo") (typed-echo [word GString]) (hasheq 'word word)])

(define nt-routes
  (append conf-typed
          (list (GET "api/ping" (lambda (_req) (hasheq 'pong #t)))
                (GET "api/stream"
                     (lambda (_req)
                       (streaming-response (lambda (out)
                                             (for ([chunk (in-list '("alpha-" "beta-" "gamma-"))])
                                               (sleep 0.05)
                                               (display chunk out)
                                               (flush-output out))))))
                (GET "api/slow"
                     (lambda (_req)
                       (streaming-response
                        (lambda (out)
                          (let loop ([i 0])
                            (when (< i 100)
                              ;; The transport signals cancel by breaking the writer and
                              ;; closing the stream pipe; both surfaces are observable.
                              (with-handlers ([exn:break? (lambda (_e) (set-box! slow-canceled #t))]
                                              [exn:fail? (lambda (_e) (set-box! slow-canceled #t))])
                                (display (format "tick-~a;" i) out)
                                (flush-output out)
                                (sleep 0.05)
                                (loop (add1 i)))))))))
                (POST "api/conf-ready"
                      (lambda (_req)
                        (thread (lambda ()
                                  (for ([n (in-list '(1 2 3))])
                                    (sleep 0.1)
                                    (bus-broadcast! conf-bus 'conf-evt (hasheq 'n n)))))
                        (hasheq 'ready #t)))
                (POST "api/conf-done"
                      (lambda (req)
                        (set-box! conf-results (request-json-body req))
                        (semaphore-post conf-sema)
                        (hasheq 'saved #t))))))

(define nt (start-native-transport #:api nt-routes #:events conf-bus #:public-dir nt-dir))
(define nt-closed? (box #f))
(define ntw
  (open-webview (native-app-origin)
                #:title "glaze e2e native"
                #:width 640
                #:height 480
                #:native-transport nt
                #:on-close (lambda () (set-box! nt-closed? #t))))
(check! "open: native window opens" (webview? ntw))
(define nt-url-ok?
  (wait-until (lambda ()
                (and (webview-url ntw) (string-prefix? (webview-url ntw) (native-app-origin))))))
(check! "resource load: native page committed from the controlled origin" nt-url-ok?)

(define conf-done? (wait-until (lambda () (semaphore-try-wait? conf-sema)) 60))
(unless conf-done?
  (log (format "conf timeout: stats=~s error~s"
               (native-transport-stats nt)
               (and (webview? ntw) (webview-last-error)))))
(check! "hello: GLZ1 hello reports the command surface" (and conf-done? #t))
(define results (unbox conf-results))
(for ([step (in-list '(hello ping typed-ok typed-bad burst stream cancel events))])
  (define r (and (hash? results) (hash-ref results step #f)))
  (check! (format "~a: page reports pass" step) (and (hash? r) (equal? (hash-ref r 'ok #f) #t)))
  (define detail (and (hash? r) (hash-ref r 'detail #f)))
  (when (and detail (not (equal? detail "invalid-args")))
    (log (format "~a detail: ~s" step detail))))
(check! "typed invoke: invalid param rejected with invalid-args"
        (equal? (and (hash? results) (hash-ref (hash-ref results 'typed-bad #f) 'detail #f))
                "invalid-args"))
(check! "cancel: backend writer observed the stream pipe close"
        (wait-until (lambda () (unbox slow-canceled)) 10))
(check! "events: three broadcasts delivered in order"
        (equal? (and (hash? results) (hash-ref (hash-ref results 'events #f) 'detail #f)) "1,2,3"))
(check! "navigation policy: native page really runs on the controlled origin"
        (string-prefix? (or (and (hash? results) (hash-ref results 'href #f)) "")
                        (native-app-origin)))

(define nt-stats (native-transport-stats nt))
(log (format "native stats: ~s" nt-stats))
(check! "resource load: scheme served the page resources"
        (>= (hash-ref nt-stats 'resources-served 0) 1))
(check! "native transport: message handler carried the battery"
        (>= (hash-ref nt-stats 'messages-received 0) 6))

;; Deterministic teardown: close, then shut the transport down twice —
;; both calls must return promptly (no hang) and the stats must freeze.
(webview-close ntw)
(sleep 0.5)
(check! "close: native window on-close fired" (unbox nt-closed?))
(check! "close: closed? reports closed" (webview-closed? ntw))
(define sd1-thread (thread (lambda () (native-transport-shutdown! nt))))
(check! "teardown: shutdown returns promptly" (sync/timeout 10 sd1-thread))
(define stats-after-shutdown (native-transport-stats nt))
(define sd2-thread (thread (lambda () (native-transport-shutdown! nt))))
(check! "teardown: repeated shutdown is idempotent" (sync/timeout 5 sd2-thread))
(check! "teardown: stats frozen after shutdown"
        (equal? (native-transport-stats nt) stats-after-shutdown))

;; ---- per-window denial ----
;; Every window is its own identity: run-app carries the full authority,
;; but a second window opened with #:capability gets its own transport
;; carrying only that authority. Its page invokes a protected route,
;; catches the typed denial, and reports the code through an allowed
;; route — proving grants attach to the window, not a shared origin.
(define pw-dir (make-temporary-file "glaze-e2e-pw-~a" 'directory))
(define (pw-page invoke-js)
  (string-append "<!DOCTYPE html><html><head><title>pw</title>"
                 "<script src=\"/glaze/api.js\"></script></head><body>pw</body>"
                 "<script>"
                 invoke-js
                 "</script></html>"))
(call-with-output-file
 (build-path pw-dir "index.html")
 (lambda (o)
   (display
    (pw-page
     "glaze.invoke('api/ping').then(function () { return glaze.invoke('api/open-second-window'); })")
    o)))
(call-with-output-file
 (build-path pw-dir "restricted.html")
 (lambda (o)
   (display
    (pw-page
     "glaze.invoke('api/secret').catch(function (e) { return glaze.invoke('api/report-denied', { code: e.code }); })")
    o)))
(define pw-denied (box #f))
(define pw-sema (make-semaphore 0))
(define pw-routes
  (list (GET "api/ping" (lambda (_req) (hasheq 'pong #t)))
        (GET "api/secret" #:permission 'secret:read (lambda (_req) (hasheq 'classified #t)))
        (POST "api/report-denied"
              (lambda (req)
                (set-box! pw-denied (request-json-body req))
                (semaphore-post pw-sema)
                (hasheq 'saved #t)))
        (POST "api/open-second-window"
              (lambda (_req)
                (open-app-window "glaze://app/restricted.html"
                                 #:title "restricted"
                                 #:capability (make-capability "pw-limited" '(other:thing)))
                (hasheq 'opened #t)))))
(define pw-thread
  (thread (lambda ()
            (with-handlers ([exn:fail? (lambda (e)
                                         (fprintf (current-error-port)
                                                  "[e2e] pw run-app exn: ~a\n"
                                                  (exn-message e)))])
              (run-app #:public-dir pw-dir
                       #:api pw-routes
                       #:transport 'native
                       #:api-token #f
                       #:capability (make-capability "pw-full" '(secret:read other:thing))
                       #:title "per-window"
                       #:on-ready (lambda (_wv _u)
                                    (thread (lambda ()
                                              (sync/timeout 30 pw-sema)
                                              (sleep 0.5)
                                              (app-quit!)))))))))
(check! "per-window denial: app completed" (sync/timeout 60 (thread-dead-evt pw-thread)))
(check! "per-window denial: restricted window invoke denied"
        (equal? (and (hash? (unbox pw-denied)) (hash-ref (unbox pw-denied) 'code))
                "capability-denied"))
(delete-directory/files pw-dir)

(if (null? failures)
    (begin
      (printf "[e2e] ALL PASS\n")
      (exit 0))
    (begin
      (printf "[e2e] FAILURES: ~a\n" (string-join (reverse failures) ", "))
      (exit 1)))
