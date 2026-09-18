#lang racket/base

;; run-app: the one-call entry that composes the whole Glaze stack —
;;
;;   (run-app #:public-dir "public" #:api (list (GET "api/ping" ...)))
;;
;; picks a free port, starts the server (static + JSON API), opens the native
;; webview window, calls #:on-ready with the handle, and blocks until the
;; window closes. Returns (values kind shutdown):
;;   - kind 'webview: window closed, server already stopped; shutdown is a
;;     no-op if called again
;;   - kind 'browser: no native backend, the system browser was opened and
;;     the server keeps running — call shutdown (or exit) to stop

(require racket/random
         "server.rkt"
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
           (if (= (string-length s) 1) (string-append "0" s) s))))

;; Bound by run-app so callbacks can read the active token (empty when the
;; API is open).
(define current-api-token (make-parameter ""))

(define max-port-attempts 50)

(define (start-server-on-free-port #:public-dir public-dir
                                    #:api api-routes
                                    #:events [event-bus #f]
                                    #:api-token [api-token #t])
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
                    #:api-token api-token))))

;; Serialize shutdown and execute the underlying server shutdown at most once.
;; The previous implementation used call-with-semaphore but did not remember
;; completion, so every later call invoked raw-shutdown again despite the
;; documented idempotent contract.
(define (make-idempotent-shutdown raw-shutdown)
  (define lock (make-semaphore 1))
  (define stopped? #f)
  (lambda ()
    (call-with-semaphore
     lock
     (lambda ()
       (unless stopped?
         (raw-shutdown)
         (set! stopped? #t))))))

;; Close a window during exceptional unwinding without replacing the original
;; exception with a secondary native-backend error.
(define (close-webview/safely wv)
  (when wv
    (with-handlers ([exn? void])
      (unless (webview-closed? wv)
        (webview-close wv)))))

(define (run-app #:public-dir [public-dir "public"]
                 #:api [api-routes '()]
                 #:port [port #f]
                 #:title [title "Glaze"]
                 #:width [width 1024]
                 #:height [height 768]
                 #:fallback-browser? [fallback? #t]
                 #:background-active? [background-active? #f]
                 #:events [event-bus #f]
                 #:api-token [api-token #f]
                 #:on-close [user-on-close (lambda () (void))]
                 #:on-error [on-error #f]
                 #:check-update [check-update #f]
                 #:current-version [current-version "0.0.0"]
                 #:on-ready [on-ready (lambda (wv url) (void))])
  (when (and port
             (not (and (exact-integer? port) (<= 1 port 65535))))
    (raise-argument-error 'run-app "(or/c #f exact-integer? in [1, 65535])" port))
  (unless (string? title)
    (raise-argument-error 'run-app "string?" title))
  (unless (exact-positive-integer? width)
    (raise-argument-error 'run-app "exact-positive-integer?" width))
  (unless (exact-positive-integer? height)
    (raise-argument-error 'run-app "exact-positive-integer?" height))
  (unless (boolean? fallback?)
    (raise-argument-error 'run-app "boolean?" fallback?))
  (unless (boolean? background-active?)
    (raise-argument-error 'run-app "boolean?" background-active?))
  (unless (or (eq? api-token #t) (eq? api-token #f) (string? api-token))
    (raise-argument-error 'run-app "(or/c #t #f string?)" api-token))
  (unless (procedure? user-on-close)
    (raise-argument-error 'run-app "procedure?" user-on-close))
  (unless (or (not on-error) (procedure? on-error))
    (raise-argument-error 'run-app "(or/c #f procedure?)" on-error))
  (unless (or (not check-update) (string? check-update))
    (raise-argument-error 'run-app "(or/c #f string?)" check-update))
  (unless (string? current-version)
    (raise-argument-error 'run-app "string?" current-version))
  (unless (procedure? on-ready)
    (raise-argument-error 'run-app "procedure?" on-ready))

  (define token
    (cond
      [(eq? api-token #t) (make-api-token)]
      [(string? api-token) api-token]
      [else #f]))
  (define-values (actual-port raw-shutdown)
    (if port
        (start-server #:port port
                      #:public-dir public-dir
                      #:api api-routes
                      #:events event-bus
                      #:api-token token)
        (start-server-on-free-port #:public-dir public-dir
                                   #:api api-routes
                                   #:events event-bus
                                   #:api-token token)))
  (define url (format "http://127.0.0.1:~a/" actual-port))
  ;; Capability URL: the one-time ?glaze-token= bootstrap exchanges the token
  ;; for an HttpOnly cookie and redirects to the clean URL. Without it the
  ;; page would have no way to receive the token (api.js deliberately no
  ;; longer hands it out); programmatic clients use the X-Glaze-Token header.
  (define open-url
    (if token (format "~a?glaze-token=~a" url token) url))
  (define shutdown (make-idempotent-shutdown raw-shutdown))
  (define closed (make-semaphore 0))
  (define active-wv #f)

  ;; Once the server exists, every exceptional exit from setup/runtime must
  ;; release it. If a native window was already created, close that too.
  (with-handlers ([exn?
                   (lambda (e)
                     (close-webview/safely active-wv)
                     (with-handlers ([exn? void]) (shutdown))
                     (raise e))])
    (parameterize ([current-api-token (or token "")]
                   [current-glaze-error-reporter
                    (or on-error (current-glaze-error-reporter))])
      (define (start-update-check!)
        (when check-update
          (thread
           (lambda ()
             (define info
               (do-check-update check-update #:current-version current-version))
             (when info
               (printf "[glaze] update available: ~a (current ~a) — ~a~n"
                       (hash-ref info 'version #f)
                       current-version
                       (hash-ref info 'url #f))
               (when event-bus
                 (bus-broadcast! event-bus 'update-available info)))))))
      (define wv
        (open-window open-url
                     #:title title
                     #:width width
                     #:height height
                     #:background-active? background-active?
                     #:on-close
                     (lambda ()
                       ;; A user callback must not be able to prevent the
                       ;; lifecycle semaphore from being posted. Preserve the
                       ;; callback's exception while guaranteeing progress.
                       (dynamic-wind
                         void
                         user-on-close
                         (lambda () (semaphore-post closed))))
                     #:fallback-browser? fallback?))
      (set! active-wv wv)
      (cond
        [wv
         (on-ready wv url)
         (start-update-check!)
         (sync closed)
         (shutdown)
         (values 'webview shutdown)]
        [else
         ;; Browser fallback: no window to wait on. Leave the server running so
         ;; the browser keeps working; caller decides when to exit.
         (on-ready #f url)
         (start-update-check!)
         (printf "[glaze] app served at ~a (system-browser fallback)~n" url)
         ;; Do not print the capability token. It remains available to trusted
         ;; application callbacks through current-api-token, while the browser
         ;; receives it only through the one-time bootstrap URL.
         (printf "[glaze] call the returned shutdown procedure or exit to stop~n")
         (values 'browser shutdown)]))))

(module+ test-support
  (provide make-idempotent-shutdown))
