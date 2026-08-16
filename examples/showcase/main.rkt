#lang racket/base

;; Glaze Showcase — one window, every capability, each tab wired to the
;; real backend. Run: racket examples/showcase/main.rkt

(require racket/file
         racket/runtime-path
         glaze)

(define-runtime-path public "public")

(provide api bus wv-box)

;; ---- state & services ----------------------------------------------------
(define bus (make-event-bus))
(define wv-box (box #f))
(define wide? (box #f))
(define hits (box 0))

;; subprocess-backed actions run on a thread: osascript/open take 1-2s to
;; spawn, and answering the HTTP request first keeps the UI snappy.
(define (reveal-later!)
  (thread (lambda ()
            (reveal-path (path->string (find-system-path 'run-file)))))
  #t)

;; 1 Hz event stream (SSE tab)
(void (thread (lambda ()
                (let loop ()
                  (sleep 1)
                  (bus-broadcast! bus 'tick (hasheq 'now (current-inexact-milliseconds)))
                  (loop)))))

;; error reporting: handler exceptions flow back to the page as events
(define (report-error! exn uri)
  (bus-broadcast! bus 'backend-error
                  (hasheq 'uri uri 'message (exn-message exn))))

;; ---- routes: every define-api-routes shape --------------------------------
(define-api-routes api
  ;; typed params with defaults; bad input -> 400 naming the parameter
  [(POST "api/add")
   (add [a exact-integer?] [b exact-integer? 1])
   (begin (set-box! hits (add1 (unbox hits)))
          (hasheq 'sum (+ a b) 'hits (unbox hits)))]
  ;; :path params arrive as plain arguments
  [(GET "api/echo/:msg")
   (echo msg)
   (hasheq 'echo msg 'len (string-length msg))]
  ;; handler exceptions -> 500 + the on-error hook (see run-app below)
  [(POST "api/boom")
   (boom)
   (raise-user-error 'showcase "boom: 数据处理故意失败 (演示 500 + 错误上报)")]
  ;; system integration
  [(POST "api/clip-write")
   (clip-write text)
   (hasheq 'ok (clipboard-set! text))]
  [(POST "api/clip-read")
   (clip-read)
   (hasheq 'text (clipboard-get))]
  [(POST "api/notify")
   (do-notify title body)
   (begin (thread (lambda () (notify! title body #:subtitle "showcase")))
          (hasheq 'ok #t))]
  [(POST "api/reveal")
   (do-reveal)
   (hasheq 'ok (reveal-later!))]
  ;; window controls (handle arrives via #:on-ready)
  [(POST "api/win-title")
   (win-title n)
   (let ([t (format "Showcase ~a" n)])
     (and (unbox wv-box) (webview-set-title! (unbox wv-box) t))
     (hasheq 'title t))]
  [(POST "api/win-size")
   (win-size)
   (let* ([w? (not (unbox wide?))])
     (set-box! wide? w?)
     (and (unbox wv-box)
          (webview-set-size! (unbox wv-box) (if w? 1080 860) (if w? 700 560)))
     (hasheq 'size (if w? "1080x700" "860x560")))]
  [(POST "api/focus")
   (do-focus)
   (begin (and (unbox wv-box) (webview-focus! (unbox wv-box)))
          (hasheq 'ok #t))]
  [(POST "api/fullscreen")
   (fullscreen)
   (and (unbox wv-box) (webview-set-fullscreen! (unbox wv-box) #t)
        (sleep 1.2)
        (webview-set-fullscreen! (unbox wv-box) #f))
   (hasheq 'now "toggled and back")]
  ;; verification APIs: the agent workflow, on demand
  [(POST "api/self-check")
   (self-check)
   (let* ([wv (unbox wv-box)]
          [shot (and wv (webview-capture! wv (build-path public "shots" "latest.png")))]
          [pass? (and wv
                      (equal? (webview-title wv) "Glaze Showcase")
                      shot
                      (>= (file-size shot) 5000))])
     (hasheq 'ok (and pass? #t)
             'title (and wv (webview-title wv))
             'url (and wv (webview-url wv))
             'shot-bytes (and shot (file-size shot))))]
  ;; update check against a local manifest (v99 > current)
  [(POST "api/check-update")
   (check-update-now)
   (let ([info (check-update "http://127.0.0.1:18952/manifest.json"
                             #:current-version "0.3.0")])
     (hasheq 'found (and info #t) 'info info))]
  ;; token-guarded secret (guarded by #:api-token below)
  [(POST "api/secret")
   (secret)
   (hasheq 'secret "the cake is a lie")])

;; a deliberately hostile manifest for the update tab
(call-with-output-file (build-path public "manifest.json")
  (lambda (o)
    (write-bytes (string->bytes/utf-8
                  "{\"version\":\"99.0.0\",\"url\":\"https://example.com/99\",\"notes\":\"showcase manifest\"}") o))
  #:exists 'replace)

(module+ main
  (unless (single-instance? "glaze-showcase")
    (displayln "[showcase] another instance is running; exiting")
    (exit 1))

  ;; tray: About re-focuses the window, Quit exits
  (define tray
    (make-tray #:icon #f
               #:tooltip "Glaze Showcase"
               #:menu (list
                       (make-menu-item "关于 / About"
                                       #:action (lambda ()
                                                  (and (unbox wv-box)
                                                       (webview-set-title!
                                                        (unbox wv-box)
                                                        "Glaze Showcase"))))
                       (menu-separator)
                       (make-menu-item "退出 / Quit"
                                       #:action (lambda () (exit 0))))))

  (run-app
   #:public-dir public
   #:api api
   #:events bus
   #:api-token "showcase-demo-token"
   #:title "Glaze Showcase"
   #:width 860 #:height 560
   #:port 18952
   #:on-error report-error!
   #:on-ready
   (lambda (wv url)
     (when wv
       (set-box! wv-box wv)
       ;; boot self-check: WKWebView in a bare (non-bundle) process
       ;; occasionally stalls before first paint — detect and reload once.
       (thread
        (lambda ()
          (sleep 4)
          (define t1 (webview-title wv))
          (fprintf (current-error-port) "[showcase] boot check #1: title=~s url=~s\n"
                   t1 (webview-url wv))
          (flush-output (current-error-port))
          (when (or (not t1) (string=? t1 ""))
            (fprintf (current-error-port) "[showcase] page stalled — reloading\n")
            (flush-output (current-error-port))
            (webview-navigate wv url)
            (sleep 3)
            (fprintf (current-error-port) "[showcase] boot check #2: title=~s\n"
                     (webview-title wv))
            (flush-output (current-error-port)))))))))
