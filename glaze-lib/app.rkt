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

(require "server.rkt"
         "webview/main.rkt")

(provide run-app)

(define max-port-attempts 50)

(define (start-server-on-free-port #:public-dir public-dir #:api api-routes)
  (let loop ([attempts 0])
    (define candidate (+ 20000 (random 45000)))
    (with-handlers ([exn:fail:network? (lambda (e)
                                         (if (< attempts max-port-attempts)
                                             (loop (add1 attempts))
                                             (raise e)))])
      (start-server #:port candidate #:public-dir public-dir #:api api-routes))))

(define (run-app #:public-dir [public-dir "public"]
                 #:api [api-routes '()]
                 #:port [port #f]
                 #:title [title "Glaze"]
                 #:width [width 1024]
                 #:height [height 768]
                 #:fallback-browser? [fallback? #t]
                 #:on-close [user-on-close (lambda () (void))]
                 #:on-ready [on-ready (lambda (wv url) (void))])
  (define-values (actual-port raw-shutdown)
    (if port
        (start-server #:port port #:public-dir public-dir #:api api-routes)
        (start-server-on-free-port #:public-dir public-dir #:api api-routes)))
  (define url (format "http://127.0.0.1:~a/" actual-port))
  ;; Once-guard so callers may always call shutdown, even after run-app
  ;; already stopped the server on window close.
  (define once (make-semaphore 1))
  (define (shutdown)
    (call-with-semaphore once (lambda () (raw-shutdown))))
  (define closed (make-semaphore 0))
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
     (printf "[glaze] call the returned shutdown procedure or exit to stop~n")
     (values 'browser shutdown)]))
