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
         glaze/server
         glaze/webview/main)

;; stderr logging so the run leaves evidence in CI logs.
(define (log msg) (fprintf (current-error-port) "[e2e] ~a\n" msg))

(define failures '())
(define (check! name ok?)
  (printf "[e2e] ~a ~a\n" (if ok? "PASS" "FAIL") name)
  (unless ok? (set! failures (cons name failures))))

(define (wait-until pred [secs 30])
  (define deadline (+ (current-inexact-milliseconds) (* secs 1000)))
  (let loop ()
    (cond
      [(pred) #t]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else (sleep 0.25) (loop)])))

(define dir (make-temporary-file "glaze-e2e-~a" 'directory))
(for ([page '("index.html" "p2.html")]
      [doc '(("<title>E2E One</title>" "ONE") ("<title>E2E Two</title>" "TWO"))])
  (call-with-output-file (build-path dir page)
    (lambda (o)
      (fprintf o
               "<html><head>~a</head><body style=\"background:#C15F3C;color:#fff\"><h1>~a</h1></body></html>"
               (first doc)
               (second doc)))
    #:exists 'replace))

(define-values (port stop) (start-server #:port 18970 #:public-dir dir))
(printf "[e2e] server up on ~a, backend-supported?=~a\n" port (webview-supported?))

(define closed? (box #f))
(define wv (open-window (format "http://127.0.0.1:~a/" port)
                        #:title "glaze e2e"
                        #:width 640
                        #:height 480
                        #:on-close (lambda () (set-box! closed? #t))))
(check! "open-window returns webview" (webview? wv))
(unless (webview? wv)
  (printf "[e2e] backend unavailable on this host — FAIL\n")
  (exit 1))

(check! "page 1 title commits"
        (wait-until (lambda () (equal? (webview-title wv) "E2E One"))))
(check! "page 1 url" (equal? (webview-url wv) (format "http://127.0.0.1:~a/" port)))

;; capture: may need the window to composite first.
(define shot
  (let retry ([deadline (+ (current-inexact-milliseconds) 10000)])
    (define s (and (webview? wv) (webview-capture! wv)))
    (cond
      [(and s (file-exists? s) (>= (file-size s) 2000)) s]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else (sleep 0.3) (retry deadline)])))
(check! "capture produces a non-trivial PNG" (and shot #t))
(when shot (log (format "capture: ~a (~a bytes)" shot (file-size shot))))

(webview-navigate wv (format "http://127.0.0.1:~a/p2.html" port))
(check! "navigate -> page 2 title commits"
        (wait-until (lambda () (equal? (webview-title wv) "E2E Two"))))

(webview-close wv)
(sleep 0.5)
(check! "on-close fired" (unbox closed?))

(stop)
(delete-directory/files dir)

(if (null? failures)
    (begin (printf "[e2e] ALL PASS\n") (exit 0))
    (begin (printf "[e2e] FAILURES: ~a\n" (string-join (reverse failures) ", "))
           (exit 1)))
