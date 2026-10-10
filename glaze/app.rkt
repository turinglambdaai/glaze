#lang racket/base

;; run-app: the one-call entry that composes the whole Glaze stack —
;;
;;   (run-app #:public-dir "public" #:api (list (GET "api/ping" ...)))
;;
;; picks a free port, starts the server (static + JSON API), opens the native
;; WebView window, calls #:on-ready with the handle, and blocks until the
;; window closes. Returns (values 'webview shutdown); shutdown is a no-op if
;; called again after the normal window-close path.
;;
;; Native GUI is the application contract. If the platform WebView cannot
;; start, run-app stops the local server and propagates the actionable startup
;; error from glaze/webview. It never opens the system browser as a fallback.

(require racket/random
         "server.rkt"
         "capability.rkt"
         "events.rkt"
         (rename-in "update.rkt" [check-update do-check-update])
         "webview/main.rkt")

(provide run-app
         make-api-token
         current-api-token)

;; Random 32-hex-char capability token (racket/random's CSPRNG).
(define (make-api-token)
  (apply string-append
         (for/list ([b (in-list (bytes->list (crypto-random-bytes 16)))])
           (define s (number->string b 16))
           (if (= (string-length s) 1)
               (string-append "0" s)
               s))))

;; Bound by run-app so callbacks can read the active token (empty when the
;; API is open).
(define current-api-token (make-parameter ""))

(define max-port-attempts 50)

(define (start-server-on-free-port #:public-dir public-dir
                                   #:api api-routes
                                   #:events [event-bus #f]
                                   #:api-token [api-token #f]
                                   #:capability [authority #f]
                                   #:max-body-size [max-body-size (* 8 1024 1024)])
  (let loop ([attempts 0])
    (define candidate (+ 20000 (random 45000)))
    (with-handlers ([exn:fail:network? (lambda (e)
                                         (if (< attempts max-port-attempts)
                                             (loop (add1 attempts))
                                             (raise e)))])
      (start-server #:port candidate
                    #:public-dir public-dir
                    #:api api-routes
                    #:events event-bus
                    #:api-token api-token
                    #:capability authority
                    #:max-body-size max-body-size))))

;; run-app defaults to a token-protected bridge: the loopback port is
;; reachable by every web page in every browser, so an open local API is a
;; drive-by CSRF target. The WebView receives its cookie through the
;; ?glaze-token= bootstrap transparently; programmatic clients use the
;; X-Glaze-Token header or the same bootstrap URL. Pass #:api-token #f
;; explicitly to run a fully open bridge (dev tooling, trusted kiosk apps).
(define (run-app #:public-dir [public-dir "public"]
                 #:api [api-routes '()]
                 #:port [port #f]
                 #:title [title "Glaze"]
                 #:width [width 1024]
                 #:height [height 768]
                 #:events [event-bus #f]
                 #:api-token [api-token #t]
                 #:capability [authority #f]
                 #:max-body-size [max-body-size (* 8 1024 1024)]
                 #:on-close [user-on-close (lambda () (void))]
                 #:on-error [on-error #f]
                 #:check-update [check-update #f]
                 #:current-version [current-version "0.0.0"]
                 #:app-id [app-id #f]
                 #:window-state [window-state-option #f]
                 #:on-ready [on-ready (lambda (wv url) (void))])
  (when (and authority (not (capability? authority)))
    (raise-argument-error 'run-app "(or/c #f capability?)" authority))
  (define state-path
    (cond
      [(not window-state-option) #f]
      [(eq? window-state-option #t)
       (unless (and (string? app-id) (not (string=? app-id "")))
         (raise-arguments-error 'run-app
                                "#:app-id is required when #:window-state is #t"
                                "app-id"
                                app-id))
       (default-window-state-path app-id)]
      [(path-string? window-state-option) window-state-option]
      [else (raise-argument-error 'run-app "(or/c #f #t path-string?)" window-state-option)]))
  (define token
    (cond
      [(string? api-token) api-token]
      ;; A capability cannot work without a token: start-server would reject
      ;; it, so #f under authority still mints one (historical contract).
      [(or authority (eq? api-token #t)) (make-api-token)]
      [else #f]))
  (define-values (actual-port raw-shutdown)
    (if port
        (start-server #:port port
                      #:public-dir public-dir
                      #:api api-routes
                      #:events event-bus
                      #:api-token token
                      #:capability authority
                      #:max-body-size max-body-size)
        (start-server-on-free-port #:public-dir public-dir
                                   #:api api-routes
                                   #:events event-bus
                                   #:api-token token
                                   #:capability authority
                                   #:max-body-size max-body-size)))
  (define url (format "http://127.0.0.1:~a/" actual-port))
  ;; Capability URL: the one-time ?glaze-token= bootstrap exchanges the token
  ;; for an HttpOnly cookie and redirects to the clean URL. Without it the
  ;; page would have no way to receive the token (api.js deliberately no
  ;; longer hands it out); programmatic clients use the X-Glaze-Token header.
  (define open-url
    (if token
        (format "~a?glaze-token=~a" url token)
        url))
  ;; Once-only shutdown. The semaphore serializes concurrent callers; the
  ;; flag turns a second call (after the normal window-close path) into a
  ;; no-op instead of a second raw-shutdown.
  (define once (make-semaphore 1))
  (define shut-down? #f)
  (define (shutdown)
    (call-with-semaphore once
                         (lambda ()
                           (unless shut-down?
                             (set! shut-down? #t)
                             (raw-shutdown)))))
  (define closed (make-semaphore 0))
  (parameterize ([current-api-token (or token "")]
                 [current-glaze-error-reporter (or on-error (current-glaze-error-reporter))])
    ;; Callbacks may fire on backend threads that never entered this
    ;; parameterize; capture the reporter once so on-error applies to them.
    (define reporter (current-glaze-error-reporter))
    ;; Update check runs in the background: the fetch has a multi-second
    ;; network timeout and a GUI app must not stall first paint on it. The
    ;; 'update-available broadcast keeps its original contract (same event,
    ;; same payload) — consumers cannot tell it arrived asynchronously.
    (when check-update
      (thread (lambda ()
                (define info (do-check-update check-update #:current-version current-version))
                (when info
                  (printf "[glaze] update available: ~a (current ~a) — ~a~n"
                          (hash-ref info 'version #f)
                          current-version
                          (hash-ref info 'url #f))
                  (when event-bus
                    (bus-broadcast! event-bus 'update-available info))))))
    ;; If native GUI startup fails, never leave the local HTTP server behind.
    ;; open-window's exception contains the platform-specific install/repair
    ;; instructions; preserve it unchanged for the caller/user.
    (define wv
      (with-handlers ([exn:fail? (lambda (e)
                                   (shutdown)
                                   (raise e))])
        (open-window open-url
                     #:title title
                     #:width width
                     #:height height
                     #:window-state state-path
                     #:on-close
                     (lambda ()
                       ;; A user on-close hook that raises must
                       ;; never leave run-app blocked on `closed`
                       ;; forever: report and finish the close.
                       (with-handlers ([exn:fail? (lambda (e) (reporter e "app:on-close"))])
                         (user-on-close))
                       (semaphore-post closed)))))
    ;; #:on-ready runs before the event loop owns the window: an exception
    ;; here must tear the window AND the server down, or both outlive run-app.
    (with-handlers ([exn:fail? (lambda (e)
                                 (with-handlers ([exn:fail? (lambda (_) (void))])
                                   (webview-close wv))
                                 (shutdown)
                                 (raise e))])
      (on-ready wv url))
    (sync closed)
    (shutdown)
    (values 'webview shutdown)))
