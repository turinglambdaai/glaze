#lang racket/base

;; Cross-platform WebView end-to-end check. Exits 0 on success, 1 on
;; failure — designed for CI (runs on a real desktop session on all three
;; OSes; on Linux run under xvfb-run).
;;
;; Verifies per backend: open -> first page loads (title commits) ->
;; capture -> navigate -> second page loads -> close -> on-close fired.
;;
;;   racket scripts/webview-e2e.rkt          (macOS / Windows)
;;   xvfb-run -a racket scripts/webview-e2e.rkt   (Linux)

(require racket/file
         racket/list
         racket/string
         glaze/api
         glaze/native-transport
         glaze/server
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
(check! "open-window returns webview" (webview? wv))
(unless (webview? wv)
  (printf "[e2e] backend unavailable on this host — FAIL\n")
  (exit 1))

(define title1-ok? (wait-until (lambda () (equal? (webview-title wv) "E2E One"))))
(unless title1-ok?
  (log (format "timeout: title=~s url=~s" (webview-title wv) (webview-url wv))))
(check! "page 1 title commits" title1-ok?)
(check! "page 1 url" (equal? (webview-url wv) (format "http://127.0.0.1:~a/" port)))

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
(check! "capture contains composited page pixels" (and shot #t))
(when shot
  (log (format "capture: ~a (~a bytes)" shot (file-size shot))))

(webview-navigate wv (format "http://127.0.0.1:~a/p2.html" port))
(define title2-ok? (wait-until (lambda () (equal? (webview-title wv) "E2E Two"))))
(unless title2-ok?
  (log (format "nav timeout: title=~s url=~s" (webview-title wv) (webview-url wv))))
(check! "navigate -> page 2 title commits" title2-ok?)

(webview-close wv)
(sleep 0.5)
(check! "on-close fired" (unbox closed?))
(check! "window state persisted on close" (window-state? (read-window-state state-path)))

(stop)
(delete-directory/files dir)
(when (file-exists? state-path)
  (delete-file state-path))

;; ---- native transport: controlled scheme + GLZ1 message handler ----
;; The page loads from glaze://app/ (never a TCP port) and invokes the
;; backend through the host's message handler; recording the result via a
;; second invoke proves the FULL loop: bootstrap injected at document
;; start, message reached the transport, dispatch ran the route, and the
;; response was delivered back into the page's promise chain.
(require glaze/api
         glaze/native-transport)
(define nt-dir (make-temporary-file "glaze-e2e-native-~a" 'directory))
(define nt-page
  (string-append
   "<!DOCTYPE html><html><head><title>native-e2e</title>"
   "<script src=\"/glaze/api.js\"></script></head><body>native</body>"
   "<script>"
   "glaze.invoke('api/ping')"
   ".then(function (v) { return glaze.invoke('api/record', { pong: v.pong, href: location.href }); })"
   ".catch(function (e) { window.__glz1Error = String(e); });"
   "</script></html>"))
(call-with-output-file (build-path nt-dir "index.html")
                       (lambda (o) (display nt-page o))
                       #:exists 'replace)
(define nt-recorded (box #f))
(define nt-done (make-semaphore 0))
(define nt-routes
  (list (GET "api/ping" (lambda (_req) (hasheq 'pong #t)))
        (POST "api/record"
              (lambda (req)
                (set-box! nt-recorded (request-json-body req))
                (semaphore-post nt-done)
                (hasheq 'saved #t)))))
(define nt (start-native-transport #:api nt-routes #:public-dir nt-dir))
(define nt-closed? (box #f))
(define ntw
  (open-webview "glaze://app/"
                #:title "glaze e2e native"
                #:width 640
                #:height 480
                #:native-transport nt
                #:on-close (lambda () (set-box! nt-closed? #t))))
(check! "native window opens" (webview? ntw))
(define nt-url-ok?
  (wait-until (lambda () (and (webview-url ntw) (string-prefix? (webview-url ntw) "glaze://app/")))))
(check! "native page committed from the glaze scheme" nt-url-ok?)
(define nt-roundtrip-ok? (wait-until (lambda () (unbox nt-recorded)) 30))
(check! "native invoke round trip reached the backend" (and nt-roundtrip-ok? #t))
(check! "native result carries the invoke value"
        (equal? (and (hash? (unbox nt-recorded)) (hash-ref (unbox nt-recorded) 'pong)) #t))
(check! "native page really runs on the glaze scheme"
        (string-prefix? (or (and (hash? (unbox nt-recorded)) (hash-ref (unbox nt-recorded) 'href #f))
                            "")
                        "glaze://app/"))
(define nt-stats (native-transport-stats nt))
(check! "scheme served the page resources" (>= (hash-ref nt-stats 'resources-served 0) 1))
(check! "message handler carried both invokes" (>= (hash-ref nt-stats 'messages-received 0) 2))
(webview-close ntw)
(sleep 0.5)
(check! "native window on-close fired" (unbox nt-closed?))
(native-transport-shutdown! nt)
(delete-directory/files nt-dir)

(if (null? failures)
    (begin
      (printf "[e2e] ALL PASS\n")
      (exit 0))
    (begin
      (printf "[e2e] FAILURES: ~a\n" (string-join (reverse failures) ", "))
      (exit 1)))
