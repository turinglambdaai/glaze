#lang racket/base

;; Glaze WebView demo (macOS). Serves two pages from a temp dir, opens a
;; native NSWindow + WKWebView, auto-navigates to page 2 after a while, and
;; exits when you close the window (red button) or after the watchdog —
;; exercising the whole surface: rendering, JS execution, webview-navigate,
;; verification APIs, and the on-close callback.
;;
;; Run: racket examples/webview-demo.rkt

(require racket/file
         glaze/server
         glaze/webview/main)

(define (say fmt . args)
  (apply printf fmt args)
  (flush-output (current-output-port)))

(define dir (make-temporary-file "glaze-demo-~a" 'directory))
(call-with-output-file (build-path dir "index.html")
  (lambda (o) (display
    #<<HTML
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Glaze Demo</title><style>
  body{font-family:-apple-system,sans-serif;background:#F4F3EE;color:#2d2a26;
       display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
  .card{max-width:560px;text-align:center;padding:48px}
  h1{font-size:44px;font-weight:800;margin:0 0 8px}
  h1 em{color:#C15F3C;font-style:normal}
  p.sub{color:#6b675f;font-size:16px;margin:0 0 28px}
  button{background:#C15F3C;color:#fff;border:none;border-radius:10px;
         padding:14px 28px;font-size:17px;font-weight:600;cursor:pointer}
  button:active{transform:scale(.97)}
  #count{font-size:60px;font-weight:800;color:#C15F3C;margin:24px 0 4px}
  .hint{margin-top:28px;font-size:13px;color:#9a958a}
</style></head><body><div class="card">
  <h1>Glaze <em>on macOS</em></h1>
  <p class="sub">NSWindow + WKWebView，由 Racket 纯 FFI 创建，无 C 编译</p>
  <div id="count">0</div>
  <button onclick="bump()">点我试试（JS 在跑）</button>
  <p class="hint">约 20 秒后 Racket 会调用 webview-navigate 跳到第二页<br>
     点红色关闭按钮，Racket 侧 on-close 将触发并退出</p>
</div><script>
  let n = 0;
  function bump(){ n++; document.getElementById('count').textContent = n; }
</script></body></html>
HTML
    o)) #:exists 'replace)
(call-with-output-file (build-path dir "page2.html")
  (lambda (o) (display
    #<<HTML
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Navigated</title><style>
  body{font-family:-apple-system,sans-serif;background:#1e1e2e;color:#eee;
       display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
  .card{text-align:center}
  h1{font-size:40px;font-weight:800;color:#89b4fa}
  p{color:#a6adc8;font-size:16px}
  code{background:#313244;padding:2px 8px;border-radius:6px;font-size:14px}
</style></head><body><div class="card">
  <h1>webview-navigate ✓</h1>
  <p>这一页是 Racket 在运行时调 <code>(webview-navigate wv url)</code> 载入的</p>
  <p id="t"></p>
</div><script>
  document.getElementById('t').textContent =
    'JS 时间: ' + new Date().toLocaleTimeString();
</script></body></html>
HTML
    o)) #:exists 'replace)

(define-values (port stop) (start-server #:port 18941 #:public-dir dir))
(say "[demo] server up on 127.0.0.1:~a\n" port)

(define closed? (box #f))
(define wv (open-window (format "http://127.0.0.1:~a/" port)
                        #:title "Glaze · macOS Demo"
                        #:width 960
                        #:height 680
                        #:on-close (lambda () (set-box! closed? #t))))
(unless wv
  (error 'demo "webview backend unavailable — run this on macOS"))
(say "[demo] window opened (backend=~a)\n" (webview-backend wv))

(define tmp (path->string (find-system-path 'temp-dir)))

(define (wait-for want what [secs 15])
  (define deadline (+ (current-inexact-milliseconds) (* secs 1000)))
  (let loop ()
    (cond
      [(equal? (webview-title wv) want)
       (say "[demo] ~a ok — title=~s url=~s\n" what (webview-title wv) (webview-url wv))]
      [(> (current-inexact-milliseconds) deadline)
       (say "[demo] ~a TIMEOUT (title=~s)\n" what (webview-title wv))]
      [else (sleep 0.2) (loop)])))

(define (snap tag)
  (define p (string-append tmp "glaze-demo-" tag ".png"))
  (let retry ([deadline (+ (current-inexact-milliseconds) 5000)])
    (define s (webview-capture! wv p))
    (cond
      [(and s (>= (file-size s) 5000)) (say "[demo] capture ~a -> ~a (~a bytes)\n" tag s (file-size s))]
      [(> (current-inexact-milliseconds) deadline) (say "[demo] capture ~a FAILED\n" tag)]
      [else (sleep 0.3) (retry deadline)])))

(wait-for "Glaze Demo" "page 1 load")
(snap "page1")
(say "[demo] page 1 live — auto-navigating in 20s (close the window any time)\n")
(sleep 20)
(unless (unbox closed?)
  (webview-navigate wv (format "http://127.0.0.1:~a/page2.html" port))
  (wait-for "Navigated" "page 2 navigate")
  (snap "page2")
  (say "[demo] idle — close the window, or the watchdog closes it in 30s\n"))

;; Wait for user close, with a 30s watchdog that exercises the same
;; programmatic close path.
(sync/timeout 30
              (thread (lambda ()
                        (let loop ()
                          (unless (unbox closed?)
                            (sleep 0.2)
                            (loop))))))
(unless (unbox closed?)
  (say "[demo] watchdog — closing programmatically\n")
  (webview-close wv)
  (sleep 0.5))
(say "[demo] on-close fired — shutting down\n")
(stop)
(delete-directory/files dir)
(say "[demo] bye\n")
