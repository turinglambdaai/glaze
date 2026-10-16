#lang racket/base

;; WebView API tests. The macOS backend end-to-end section is gated on
;; 'macosx (mirrors the Windows tray backend tests in main.rkt): the open ->
;; navigate -> close round trip is verifiable even on a headless CI host
;; because none of it waits for page rendering (about:blank), and on-close is
;; delivered synchronously via performClose:.

(require rackunit
         racket/async-channel
         racket/file
         racket/string
         glaze/api
         glaze/app
         glaze/capability
         glaze/events
         glaze/native-transport
         glaze/server
         glaze/webview/main)

;; ---- Public API surface (all platforms) ----
(check-equal? (procedure? open-window) #t "open-window is a procedure")
(check-equal? (procedure? open-webview) #t "open-webview is a procedure")
(check-equal? (procedure? webview-supported?) #t "webview-supported? is a procedure")
(check-equal? (procedure? webview-last-error) #t "webview-last-error is a procedure")
(check-equal? (procedure? webview-install-guidance) #t "webview-install-guidance is a procedure")
(check-equal? (procedure? webview-diagnostic) #t "webview-diagnostic is a procedure")
(check-true (positive? (string-length (webview-install-guidance)))
            "platform install guidance is non-empty")
(check-equal? (procedure? webview-navigate) #t "webview-navigate is a procedure")
(check-equal? (procedure? webview-close) #t "webview-close is a procedure")
(check-equal? (procedure? webview-title) #t "webview-title is a procedure")
(check-equal? (procedure? webview-url) #t "webview-url is a procedure")
(check-equal? (procedure? webview-capture!) #t "webview-capture! is a procedure")

;; ---- macOS WebView backend end-to-end (only on 'macosx) ----
(when (eq? (system-type 'os) 'macosx)
  (define mod-supported? (dynamic-require 'glaze/webview/webview-macos 'supported?))
  (define mod-open (dynamic-require 'glaze/webview/webview-macos 'open-webview))
  (define mod-mac:webview? (dynamic-require 'glaze/webview/webview-macos 'mac:webview?))
  (define mod-thread (dynamic-require 'glaze/webview/webview-macos 'mac:webview-thread))
  (define mod-navigate (dynamic-require 'glaze/webview/webview-macos 'navigate))
  (define mod-close (dynamic-require 'glaze/webview/webview-macos 'close))
  (check-true (mod-supported?) "macOS webview backend reports supported")
  (check-true (webview-supported?) "public webview-supported? agrees on macOS")

  ;; Direct backend handle.
  (define closed? (box #f))
  (define bw
    (mod-open "about:blank"
              #:title "glaze test"
              #:width 320
              #:height 240
              #:on-close (lambda () (set-box! closed? #t))))
  (check-true (mod-mac:webview? bw) "direct backend returns mac:webview?")
  (check-not-exn (lambda () (mod-navigate bw "about:blank")) "backend navigate does not raise")
  (check-not-exn (lambda () (mod-close bw)) "backend close does not raise")
  (sleep 0.2)
  (check-true (unbox closed?) "on-close callback fired")
  (check-not-false (sync/timeout 3 (thread-dead-evt (mod-thread bw))) "pump thread exits after close")

  ;; Public dispatcher path.
  (define closed2? (box #f))
  (define wv
    (open-window "about:blank" #:title "glaze public" #:on-close (lambda () (set-box! closed2? #t))))
  (check-true (webview? wv) "open-window returns a webview? on macOS")
  (check-equal? (webview-backend wv) 'macos "backend tag is macos")
  (check-not-exn (lambda () (webview-navigate wv "about:blank")) "navigate does not raise")
  ;; Verification APIs: url commits once the runloop services the load; give
  ;; it a bounded wait rather than a fixed sleep so slow CI hosts pass too.
  (define url-ok?
    (let deadline-loop ([deadline (+ (current-inexact-milliseconds) 10000)])
      (cond
        [(equal? (webview-url wv) "about:blank") #t]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else
         (sleep 0.1)
         (deadline-loop deadline)])))
  (check-true url-ok? "webview-url reports the committed page")
  (define tmp-png (make-temporary-file "glaze-test-cap-~a.png"))
  ;; CGWindowListCreateImage returns NULL until the window has actually been
  ;; composited to the screen, so retry briefly instead of asserting at an
  ;; arbitrary point in time.
  (define shot
    (let retry ([deadline (+ (current-inexact-milliseconds) 5000)])
      (define s (webview-capture! wv tmp-png))
      (cond
        [(and s (>= (file-size s) 1000)) s]
        [(> (current-inexact-milliseconds) deadline) s]
        [else
         (sleep 0.2)
         (retry deadline)])))
  (check-not-false shot "webview-capture! returns a path")
  (check-true (and shot (>= (file-size shot) 1000)) "capture PNG is non-trivial")
  (when (and shot (file-exists? shot))
    (delete-file shot))
  (check-not-exn (lambda () (webview-close wv)) "close does not raise")
  (sleep 0.2)
  (check-true (unbox closed2?) "public open-window on-close fired")
  (check-false (webview-capture! wv) "capture after close returns #f")

  ;; ---- multi-window: one shared pump services every open window ----
  ;; (previously one pump thread per window, all contending for the same
  ;; main run loop). Two webviews load distinct pages; both must commit,
  ;; the survivor must stay serviced after the first closes, and the pump
  ;; must exit when the last window closes.
  (define mv-dir (make-temporary-file "glaze-mv-~a" 'directory))
  (make-directory* (build-path mv-dir "a"))
  (make-directory* (build-path mv-dir "b"))
  (make-directory* (build-path mv-dir "c"))
  (call-with-output-file (build-path mv-dir "a" "index.html")
                         (lambda (o) (display "<html><head><title>alpha</title></head></html>" o)))
  (call-with-output-file (build-path mv-dir "b" "index.html")
                         (lambda (o) (display "<html><head><title>beta</title></head></html>" o)))
  (call-with-output-file (build-path mv-dir "c" "index.html")
                         (lambda (o) (display "<html><head><title>gamma</title></head></html>" o)))
  (define-values (mv-port mv-stop) (start-server #:port 18993 #:public-dir mv-dir))
  (define mod-title (dynamic-require 'glaze/webview/webview-macos 'title))
  (define closed-a? (box #f))
  (define closed-b? (box #f))
  (define wa
    (mod-open (format "http://127.0.0.1:~a/a/index.html" mv-port)
              #:title "multi-a"
              #:on-close (lambda () (set-box! closed-a? #t))))
  (define wb
    (mod-open (format "http://127.0.0.1:~a/b/index.html" mv-port)
              #:title "multi-b"
              #:on-close (lambda () (set-box! closed-b? #t))))
  ;; both pages commit through the one pump (deadline: slow CI hosts)
  (define both-loaded?
    (let dl ([deadline (+ (current-inexact-milliseconds) 10000)])
      (cond
        [(and (equal? (mod-title wa) "alpha") (equal? (mod-title wb) "beta")) #t]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else
         (sleep 0.1)
         (dl deadline)])))
  (check-true both-loaded? "shared pump services both windows")
  (mod-close wa)
  (sleep 0.2)
  (check-true (unbox closed-a?) "first window on-close fired")
  ;; survivor stays serviced after the first window closed: a fresh
  ;; navigation must still commit (title reads alone would not prove the
  ;; runloop is being pumped, since they bypass it)
  (mod-navigate wb (format "http://127.0.0.1:~a/c/index.html" mv-port))
  (define survivor-serviced?
    (let dl ([deadline (+ (current-inexact-milliseconds) 10000)])
      (cond
        [(equal? (mod-title wb) "gamma") #t]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else
         (sleep 0.1)
         (dl deadline)])))
  (check-true survivor-serviced? "survivor still serviced after first close")
  (mod-close wb)
  (sleep 0.2)
  (check-true (unbox closed-b?) "second window on-close fired")
  ;; the shared pump exits once no window remains
  (check-not-false (sync/timeout 3 (thread-dead-evt (mod-thread wb)))
                   "shared pump exits after the last window closes")
  (mv-stop)
  (delete-directory/files mv-dir)

  ;; ---- native transport end-to-end (docs/1.0-plan.md gate G4) ----
  ;; The page loads from the controlled glaze://app/ scheme (never a TCP
  ;; port) and drives the backend through the GLZ1 message handler: the
  ;; inline script invokes api/ping, then posts the result to api/record.
  ;; Recording through a second invoke proves the FULL round trip — the
  ;; bootstrap was injected at document start, the message handler reached
  ;; the transport, dispatch ran the route, and the response was delivered
  ;; back into the page's promise chain.
  (define nt-dir (make-temporary-file "glaze-nt-~a" 'directory))
  (call-with-output-file
   (build-path nt-dir "index.html")
   (lambda (o)
     (display
      (string-append
       "<!DOCTYPE html><html><head><title>native-e2e</title>"
       "<script src=\"/glaze/api.js\"></script></head><body>native</body>"
       "<script>"
       "glaze.invoke('api/ping')"
       ".then(function (v) { return glaze.invoke('api/record', { pong: v.pong, href: location.href }); })"
       ".catch(function (e) { window.__glz1Error = String(e); });"
       "</script></html>")
      o)))
  (define nt-recorded (box #f))
  (define nt-done (make-semaphore 0))
  (define nt-routes
    (list (GET "api/ping" (lambda (req) (hasheq 'pong #t)))
          (POST "api/record"
                (lambda (req)
                  (set-box! nt-recorded (request-json-body req))
                  (semaphore-post nt-done)
                  (hasheq 'saved #t)))))
  (define nt (start-native-transport #:api nt-routes #:public-dir nt-dir))
  (define mod-url (dynamic-require 'glaze/webview/webview-macos 'url))
  (define nt-closed? (box #f))
  (define ntw
    (mod-open "glaze://app/"
              #:title "native-e2e"
              #:native-transport nt
              #:on-close (lambda () (set-box! nt-closed? #t))))
  (check-true (mod-mac:webview? ntw) "native window opened")
  (define nt-url-ok?
    (let dl ([deadline (+ (current-inexact-milliseconds) 10000)])
      (cond
        [(equal? (mod-url ntw) "glaze://app/") #t]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else
         (sleep 0.1)
         (dl deadline)])))
  (check-true nt-url-ok? "page committed from the controlled glaze scheme")
  (check-not-false (sync/timeout 30 nt-done) "page invoke round trip reached the backend")
  (define nt-body (unbox nt-recorded))
  (check-equal? (and (hash? nt-body) (hash-ref nt-body 'pong)) #t "invoke returned through the page")
  (check-true (and (hash? nt-body)
                   (hash-ref nt-body 'href "")
                   (string-prefix? (hash-ref nt-body 'href) "glaze://app/"))
              "the page really runs on the glaze scheme")
  (define nt-stats (native-transport-stats nt))
  (check-true (>= (hash-ref nt-stats 'resources-served 0) 1) "the scheme handler served index.html")
  (check-true (>= (hash-ref nt-stats 'messages-received 0) 2) "both invokes arrived as messages")
  (mod-close ntw)
  (sleep 0.2)
  (check-true (unbox nt-closed?) "native window on-close fired")
  (check-not-false (sync/timeout 3 (thread-dead-evt (mod-thread ntw)))
                   "pump exits after the native window closes")
  (delete-directory/files nt-dir)

  ;; ---- run-app with #:transport 'native ----
  ;; Same loop through the public entry point: no server, tokenless, and
  ;; run-app reports the glaze:// URL to #:on-ready.
  (define ra-dir (make-temporary-file "glaze-ra-~a" 'directory))
  (call-with-output-file
   (build-path ra-dir "index.html")
   (lambda (o)
     (display
      (string-append "<!DOCTYPE html><html><head><title>runapp-native</title>"
                     "<script src=\"/glaze/api.js\"></script></head><body>ra</body>"
                     "<script>"
                     "glaze.invoke('api/ping')"
                     ".then(function (v) { return glaze.invoke('api/record', { pong: v.pong }); })"
                     ".catch(function (e) { window.__glz1Error = String(e); });"
                     "</script></html>")
      o)))
  (define ra-recorded (box #f))
  (define ra-done (make-semaphore 0))
  (define ra-url-box (box #f))
  (define ra-routes
    (list (GET "api/ping" (lambda (req) (hasheq 'pong #t)))
          (POST "api/record"
                (lambda (req)
                  (set-box! ra-recorded (request-json-body req))
                  (semaphore-post ra-done)
                  (hasheq 'saved #t)))))
  (define ra-thread
    (thread (lambda ()
              (run-app #:public-dir ra-dir
                       #:api ra-routes
                       #:transport 'native
                       #:api-token #f
                       #:title "runapp-native"
                       #:on-ready (lambda (wv u)
                                    (set-box! ra-url-box u)
                                    ;; Close once the page reported back (or on timeout, so a
                                    ;; broken bridge fails the assertions instead of hanging).
                                    (thread (lambda ()
                                              (sync/timeout 30 ra-done)
                                              (sleep 0.5)
                                              (webview-close wv))))))))
  (check-not-false (sync/timeout 45 (thread-dead-evt ra-thread)) "run-app native completed")
  (check-equal? (unbox ra-url-box) "glaze://app/" "on-ready reports the glaze scheme URL")
  (check-equal? (and (hash? (unbox ra-recorded)) (hash-ref (unbox ra-recorded) 'pong))
                #t
                "run-app native round trip recorded the invoke")
  (delete-directory/files ra-dir)

  ;; ---- per-window capability on the native transport ----
  ;; Every window is its own identity: the app runs with the full
  ;; authority, but a second window opened with #:capability gets its own
  ;; transport carrying only that authority. Its page invokes a protected
  ;; route, catches the typed denial, and reports the code through an
  ;; allowed route — proving grants attach to the window, not a shared
  ;; origin.
  (define pw-dir (make-temporary-file "glaze-pw-~a" 'directory))
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
                                                    "pw run-app exn: ~a\n"
                                                    (exn-message e)))])
                (run-app #:public-dir pw-dir
                         #:api pw-routes
                         #:transport 'native
                         #:api-token #f
                         #:capability (make-capability "pw-full" '(secret:read other:thing))
                         #:title "per-window"
                         #:on-ready (lambda (wv u)
                                      (thread (lambda ()
                                                (sync/timeout 30 pw-sema)
                                                (sleep 0.5)
                                                (app-quit!)))))))))
  (check-not-false (sync/timeout 45 (thread-dead-evt pw-thread)) "per-window app completed")
  (check-equal? (and (hash? (unbox pw-denied)) (hash-ref (unbox pw-denied) 'code))
                "capability-denied"
                "the restricted window's invoke is denied by its own capability")
  (delete-directory/files pw-dir))
