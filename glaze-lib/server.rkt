#lang racket/base

(require web-server/web-server
         web-server/http/request-structs
         web-server/http/response-structs
         web-server/http/response
         net/url
         racket/path
         racket/file
         racket/tcp
         "api.rkt")

(provide start-dev-server
         start-server
         stop-server
         path->mime-type)

;; Start a local HTTP server serving static files from public-dir on 127.0.0.1,
;; with optional JSON API routes (see api.rkt). API routes match first; other
;; requests fall through to static files with SPA index.html fallback.
;; `start-server` is the canonical name used by both dev workflow and packaged
;; apps; `start-dev-server` is kept as a backward-compatible alias.
;; Returns (values port shutdown-proc). The returned port is the requested port
;; (the underlying web-server `serve` does not currently surface the actual
;; listening port when port 0 is requested).
(define (start-server #:port [port 8080]
                      #:public-dir [public-dir "public"]
                      #:api [api-routes '()])
  (define dispatcher (make-dispatcher public-dir api-routes))
  (define shutdown-server (serve #:dispatch dispatcher #:port port #:listen-ip "127.0.0.1"))
  ;; `serve` accepts the port synchronously but the accepting loop runs in a
  ;; background thread; if that thread dies (e.g. bind race), callers saw
  ;; only "connection refused" much later. Prove the listener is accepting
  ;; before returning — fail loudly, and never hand back a dead server.
  (wait-accepting! port shutdown-server)
  (values port shutdown-server))

(define listen-wait-secs 3)

(define (wait-accepting! port shutdown-server)
  (define deadline (+ (current-inexact-milliseconds) (* listen-wait-secs 1000)))
  (define accepting?
    (let loop ()
      (define up?
        (with-handlers ([exn:fail:network? (lambda (e) #f)])
          (define-values (in out) (tcp-connect "127.0.0.1" port))
          (close-input-port in)
          (close-output-port out)
          #t))
      (cond
        [up? #t]
        [(> (current-inexact-milliseconds) deadline) #f]
        [else (sleep 0.02) (loop)])))
  (unless accepting?
    (shutdown-server)
    (raise-arguments-error
     'start-server
     (format "listener on port ~a did not start accepting within ~as"
             port listen-wait-secs)
     "port" port)))

;; Backward-compatible alias. Prefer `start-server` in new code.
(define start-dev-server start-server)

(define (stop-server shutdown-proc)
  (shutdown-proc))

(define (make-dispatcher public-dir api-routes)
  (lambda (conn req)
    (define resp
      (cond
        [(find-api-response api-routes req)]
        [(directory-exists? public-dir) (serve-static-file public-dir req)]
        [else (make-404-response)]))
    (output-response conn resp)))

;; Try each route against the request; on a match apply the handler and
;; normalize its result (jsexpr -> 200 JSON; response -> itself; exception ->
;; 500 JSON). No match -> #f (fall through to static).
(define (find-api-response api-routes req)
  (define method
    (string->symbol (string-upcase (bytes->string/latin-1 (request-method req)))))
  (define segments (path->segments req))
  (for/or ([r (in-list api-routes)])
    (define captured (route-match r method segments))
    (and captured
         (with-handlers ([exn:fail? (lambda (e)
                                      (error-response 500 (exn-message e)))])
           (define result (apply (route-handler r) req captured))
           (cond
             [(response? result) result]
             [else (api-response result)])))))

(define (serve-static-file dir req)
  (define uri-path (url-path (request-uri req)))
  (define segments (filter (lambda (s) (not (equal? s ""))) (map path/param-path uri-path)))
  (define rel
    (if (null? segments)
        '("index.html")
        segments))
  (define candidate (apply build-path dir rel))
  (cond
    [(and (file-exists? candidate) (not (directory-exists? candidate)))
     (make-file-response candidate)]
    [else
     (define fallback (build-path dir "index.html"))
     (if (file-exists? fallback)
         (make-file-response fallback)
         (make-404-response))]))

(define (make-file-response path)
  (define data (file->bytes path))
  (define mime (path->mime-type path))
  (response/full 200 #"OK" (current-seconds) mime '() (list data)))

(define (make-404-response)
  (response/full 404
                 #"Not Found"
                 (current-seconds)
                 #"text/plain; charset=utf-8"
                 '()
                 (list #"Not found")))

(define (path->mime-type p)
  (define ext (path-get-extension p))
  (cond
    [(not ext) #"application/octet-stream"]
    [(member ext '(#".html" #".htm")) #"text/html; charset=utf-8"]
    [(member ext '(#".css")) #"text/css; charset=utf-8"]
    [(member ext '(#".js" #".mjs")) #"application/javascript; charset=utf-8"]
    [(member ext '(#".json")) #"application/json; charset=utf-8"]
    [(member ext '(#".xml")) #"application/xml; charset=utf-8"]
    [(member ext '(#".txt")) #"text/plain; charset=utf-8"]
    [(member ext '(#".svg")) #"image/svg+xml"]
    [(member ext '(#".png")) #"image/png"]
    [(member ext '(#".jpg" #".jpeg")) #"image/jpeg"]
    [(member ext '(#".gif")) #"image/gif"]
    [(member ext '(#".webp")) #"image/webp"]
    [(member ext '(#".avif")) #"image/avif"]
    [(member ext '(#".ico")) #"image/x-icon"]
    [(member ext '(#".woff2")) #"font/woff2"]
    [(member ext '(#".woff")) #"font/woff"]
    [(member ext '(#".ttf")) #"font/ttf"]
    [(member ext '(#".otf")) #"font/otf"]
    [(member ext '(#".wasm")) #"application/wasm"]
    [(member ext '(#".mp4")) #"video/mp4"]
    [(member ext '(#".webm")) #"video/webm"]
    [(member ext '(#".ogg" #".ogv")) #"video/ogg"]
    [(member ext '(#".mp3")) #"audio/mpeg"]
    [(member ext '(#".map")) #"application/json; charset=utf-8"]
    [else #"application/octet-stream"]))
