#lang racket/base

;; Agent-friendly verification workflow: start an app, then assert on what
;; the UI is actually showing — page state via webview-title / webview-url,
;; pixels via webview-capture! — with no human at the screen. This is the
;; loop agents use to develop Glaze apps autonomously.
;;
;; macOS: full flow (title/url/capture). Other platforms degrade to #f and
;; the run is still a valid smoke test.
;;
;; Run: racket examples/agent-verify.rkt

(require racket/file
         racket/function
         glaze)

(define dir (make-temporary-file "glaze-verify-~a" 'directory))
(call-with-output-file (build-path dir "index.html")
  (lambda (o)
    (display "<html><head><title>Agent Target</title></head>\
<body style=\"background:#C15F3C;color:#fff;display:flex;\
align-items:center;justify-content:center;height:100vh;margin:0\">\
<h1>VERIFY ME</h1></body></html>" o))
  #:exists 'replace)

(define verdicts '())
(define skipped? #f)

(define-values (kind stop)
  (run-app #:public-dir dir
           #:title "Glaze · Agent Verify"
           #:on-ready
           (lambda (wv url)
             (cond
               [wv
                ;; Poll page state (bounded — never fixed sleeps).
                (define deadline (+ (current-inexact-milliseconds) 15000))
                (define loaded?
                  (let loop ()
                    (cond
                      [(equal? (webview-title wv) "Agent Target") #t]
                      [(> (current-inexact-milliseconds) deadline) #f]
                      [else (sleep 0.25) (loop)])))
                (set! verdicts
                      (cons (cons 'page-loaded loaded?)
                            (cons (cons 'url (equal? (webview-url wv) url))
                                  verdicts)))
                ;; Pixels: capture and inspect the PNG.
                (define shot
                  (let retry ([deadline (+ (current-inexact-milliseconds) 5000)])
                    (define s (webview-capture! wv))
                    (cond
                      [(and s (>= (file-size s) 5000)) s]
                      [(> (current-inexact-milliseconds) deadline) s]
                      [else (sleep 0.3) (retry deadline)])))
                (set! verdicts (cons (cons 'capture (and shot #t)) verdicts))
                (webview-close wv)] ; done — close drives run-app to return
               [else
                (printf "[verify] no webview backend; server at ~a\n" url)
                (set! skipped? #t)]))))

(stop)
(delete-directory/files dir)
(for ([v (in-list (reverse verdicts))])
  (printf "[verify] ~a = ~a\n" (car v) (cdr v)))
(printf "[verify] ~a\n"
        (cond
          [skipped? "SKIPPED (no webview backend on this platform)"]
          [(andmap identity (map cdr verdicts)) "ALL PASS"]
          [else "CHECK FAILURES"]))
