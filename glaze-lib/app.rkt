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
                                    #:api-token [api-token #f])
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

(define (run-app #:public-dir [public-dir "public"]
                 #:api [api-routes '()]
                 #:port [port #f]
                 #:title [title "Glaze"]
                 #:width [width 1024]
                 #:height [height 768]
                 #:fallback-browser? [fallback? #t]
                 #:events [event-bus #f]
                 #:api-token [api-token #f]
                 #:on-close [user-on-close (lambda () (void))]
                 #:on-error [on-error #f]
                 #:check-update [check-update #f]
                 #:current-version [current-version "0.0.0"]
                 #:on-ready [on-ready (lambda (wv url) (void))])
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
  ;; Once-guard so callers may always call shutdown, even after run-app
  ;; already stopped the server on window close.
  (define once (make-semaphore 1))
  (define (shutdown)
    (call-with-semaphore once (lambda () (raw-shutdown))))
  (define closed (make-semaphore 0))
  (parameterize ([current-api-token (or token "")]
                 [current-glaze-error-reporter
                  (or on-error (current-glaze-error-reporter))])
    (when check-update
      (define info (do-check-update check-update
                                       #:current-version current-version))
      (when info
        (printf "[glaze] update available: ~a (current ~a) — ~a~n"
                (hash-ref info 'version #f)
                current-version
                (hash-ref info 'url #f))
        (when event-bus
          (bus-broadcast! event-bus 'update-available info))))
    (define wv
      (open-window url
                   #:title title
                   #:width width
                   #:height height
                   #:on-close (lambda ()
                                (user-on-close)
                                (semaphore-post closed))
                   #:fallback-browser? fallback?))
    (cond
      [wv
       (on-ready wv url)
       (sync closed)
       (shutdown)
       (values 'webview shutdown)]
      [else
       ;; Browser fallback: no window to wait on. Leave the server running so
       ;; the browser keeps working; caller decides when to exit.
       (on-ready #f url)
       (printf "[glaze] app served at ~a (system-browser fallback)~n" url)
       (when token
         (printf "[glaze] api token: ~a~n" token))
       (printf "[glaze] call the returned shutdown procedure or exit to stop~n")
       (values 'browser shutdown)])))
