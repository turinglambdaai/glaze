#lang racket/base

;; run-app: the one-call entry that composes the whole Glaze stack —
;;
;;   (run-app #:public-dir "public" #:api (list (GET "api/ping" ...)))
;;
;; picks a free port, starts the server (static + JSON API), opens the native
;; WebView window, calls #:on-ready with the handle, and blocks until the app
;; quits. Returns (values 'webview shutdown); shutdown is a no-op if called
;; again after the normal quit path.
;;
;; The app is a state machine over a custodian:
;;
;;   starting -> ready -> running -> stopping -> stopped
;;
;; Every app owns a custodian; resources spawned for the app (background
;; threads such as the update check) are reaped deterministically at quit.
;; Additional windows attach to the running app through open-app-window;
;; by default the app quits when its last window closes, and
;; #:quit-on-last-window? #f keeps a tray-resident app alive until
;; app-quit!. State changes broadcast 'app-state on the event bus when one
;; is wired.
;;
;; Native GUI is the application contract. If the platform WebView cannot
;; start, run-app stops the local server and propagates the actionable
;; startup error from glaze/webview. It never opens the system browser as a
;; fallback.

(require racket/random
         "server.rkt"
         "capability.rkt"
         "events.rkt"
         (rename-in "update.rkt" [check-update do-check-update])
         "webview/main.rkt")

(provide run-app
         make-api-token
         current-api-token
         glaze-app?
         current-app
         app-id
         app-state
         app-quit!
         open-app-window)

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

;; ---- app record: the lifecycle kernel ----

;; start -> ready -> running -> stopping -> stopped (see module docs).
(struct glaze-app
        (id ; string identity (#:app-id or generated)
         state-box ; box of symbol
         custodian ; owns app-spawned resources; reaped at quit
         windows-box ; box of (listof webview?)
         windows-sema
         event-bus ; #f or event-bus? — gets 'app-state broadcasts
         quit-on-last-window?
         exit-sema ; posted by app-quit! / last-window close
         once-sema ; serializes teardown
         shut-down?-box) ; teardown happens once
  #:transparent)

(define current-app (make-parameter #f))

(define app-states '(starting ready running stopping stopped))

(define (make-app #:app-id app-id #:event-bus event-bus #:quit-on-last-window? quit-on-last-window?)
  (glaze-app (or app-id (format "glaze-app-~a" (make-api-token)))
             (box 'starting)
             (make-custodian)
             (box '())
             (make-semaphore 1)
             event-bus
             quit-on-last-window?
             (make-semaphore 0)
             (make-semaphore 1)
             (box #f)))

;; State reader: (app-state) reads the current app, (app-state app) an
;; explicit one.
(define (app-state [app (current-app)])
  (unless (glaze-app? app)
    (raise-argument-error 'app-state "glaze-app?" app))
  (unbox (glaze-app-state-box app)))

(define (app-id [app (current-app)])
  (unless (glaze-app? app)
    (raise-argument-error 'app-id "glaze-app?" app))
  (glaze-app-id app))

(define (set-app-state! app state)
  (unless (memq state app-states)
    (raise-argument-error 'set-app-state! "known app state" state))
  (set-box! (glaze-app-state-box app) state)
  (when (glaze-app-event-bus app)
    (bus-broadcast! (glaze-app-event-bus app) 'app-state (hasheq 'state state))))

(define (app-quit! [app (current-app)])
  (unless (glaze-app? app)
    (raise-argument-error 'app-quit! "glaze-app?" app))
  (unless (memq (app-state app) '(stopping stopped))
    (set-app-state! app 'stopping)
    (semaphore-post (glaze-app-exit-sema app))))

(define (register-window! app wv)
  (call-with-semaphore
   (glaze-app-windows-sema app)
   (lambda () (set-box! (glaze-app-windows-box app) (cons wv (unbox (glaze-app-windows-box app)))))))

(define (unregister-window! app wv)
  (call-with-semaphore (glaze-app-windows-sema app)
                       (lambda ()
                         (set-box! (glaze-app-windows-box app)
                                   (remq wv (unbox (glaze-app-windows-box app))))
                         (null? (unbox (glaze-app-windows-box app))))))

;; Open a window attached to the running app. Same window options as
;; open-window; the app tracks the handle so the quit policy (quit on last
;; window close vs tray-resident) can decide what a close means.
(define (open-app-window url
                         #:title [title "Glaze"]
                         #:width [width 1024]
                         #:height [height 768]
                         #:window-state [state-path #f]
                         #:on-close [user-on-close (lambda () (void))])
  (define app (current-app))
  (unless (glaze-app? app)
    (raise-arguments-error
     'open-app-window
     "no running app — open-app-window runs inside #:on-ready or after run-app started one"
     "app state"
     (if app
         (app-state app)
         "none")))
  (when (memq (app-state app) '(stopping stopped))
    (raise-arguments-error 'open-app-window "the app has already quit" "state" (app-state app)))
  (define reporter (current-glaze-error-reporter))
  (define wv
    (open-window url
                 #:title title
                 #:width width
                 #:height height
                 #:window-state state-path
                 #:on-close (lambda ()
                              (with-handlers ([exn:fail? (lambda (e) (reporter e "app:on-close"))])
                                (user-on-close))
                              (define last? (unregister-window! app wv))
                              (when (and last? (glaze-app-quit-on-last-window? app))
                                (app-quit! app)))))
  (register-window! app wv)
  wv)

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
                 #:quit-on-last-window? [quit-on-last-window? #t]
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
  (define app
    (make-app #:app-id app-id #:event-bus event-bus #:quit-on-last-window? quit-on-last-window?))
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
  ;; Once-only teardown: the semaphore serializes concurrent callers; the
  ;; flag turns a second call (after the normal quit path) into a no-op
  ;; instead of a second raw-shutdown / custodian kill.
  (define (teardown)
    (call-with-semaphore (glaze-app-once-sema app)
                         (lambda ()
                           (unless (unbox (glaze-app-shut-down?-box app))
                             (set-box! (glaze-app-shut-down?-box app) #t)
                             ;; Leftover windows (quit via app-quit! or a raising path) close
                             ;; here, on the caller's thread — the thread run-app was called
                             ;; on, which owns the native window calls.
                             (define leftover
                               (call-with-semaphore (glaze-app-windows-sema app)
                                                    (lambda ()
                                                      (define wvs (unbox (glaze-app-windows-box app)))
                                                      (set-box! (glaze-app-windows-box app) '())
                                                      wvs)))
                             (for ([wv (in-list leftover)])
                               (with-handlers ([exn:fail? (lambda (_) (void))])
                                 (webview-close wv)))
                             (raw-shutdown)
                             (custodian-shutdown-all (glaze-app-custodian app))
                             (set-app-state! app 'stopped)))))
  (parameterize ([current-api-token (or token "")]
                 [current-glaze-error-reporter (or on-error (current-glaze-error-reporter))]
                 [current-app app])
    ;; Callbacks may fire on backend threads that never entered this
    ;; parameterize; capture the reporter once so on-error applies to them.
    (define reporter (current-glaze-error-reporter))
    ;; The first window. open-app-window's on-close unregisters it and, per
    ;; the quit policy, quits the app when the last window closes.
    (define (make-on-close)
      (lambda ()
        ;; A user on-close hook that raises must never leave run-app blocked
        ;; forever: report and finish the close.
        (with-handlers ([exn:fail? (lambda (e) (reporter e "app:on-close"))])
          (user-on-close))))
    ;; Update check runs in the background under the app custodian: the
    ;; fetch has a multi-second network timeout and a GUI app must not stall
    ;; first paint on it, and the custodian reaps it at quit. The
    ;; 'update-available broadcast keeps its original contract.
    (when check-update
      (parameterize ([current-custodian (glaze-app-custodian app)])
        (thread (lambda ()
                  (define info (do-check-update check-update #:current-version current-version))
                  (when info
                    (printf "[glaze] update available: ~a (current ~a) — ~a~n"
                            (hash-ref info 'version #f)
                            current-version
                            (hash-ref info 'url #f))
                    (when event-bus
                      (bus-broadcast! event-bus 'update-available info)))))))
    ;; If native GUI startup fails, never leave the local HTTP server
    ;; behind. open-window's exception contains the platform-specific
    ;; install/repair instructions; preserve it unchanged.
    (define wv
      (with-handlers ([exn:fail? (lambda (e)
                                   (teardown)
                                   (raise e))])
        (open-app-window open-url
                         #:title title
                         #:width width
                         #:height height
                         #:window-state state-path
                         #:on-close (make-on-close))))
    (set-app-state! app 'ready)
    ;; #:on-ready runs before the event loop owns the window: an exception
    ;; here must tear the window AND the server down, or both outlive
    ;; run-app. open-app-window is main-thread land; on-ready is called on
    ;; run-app's caller thread, the same one.
    (with-handlers ([exn:fail? (lambda (e)
                                 (teardown)
                                 (raise e))])
      (on-ready wv url))
    (set-app-state! app 'running)
    (sync (glaze-app-exit-sema app))
    (teardown)
    (values 'webview teardown)))
