#lang racket/base

(require web-server/web-server
         web-server/http/request-structs
         web-server/http/response-structs
         web-server/http/response
         net/url
         racket/path
         racket/file)

(provide start-dev-server
         start-server
         stop-server
         path->mime-type)

;; Start a local HTTP server serving static files from public-dir on 127.0.0.1.
;; `start-server` is the canonical name used by both dev workflow and packaged
;; apps; `start-dev-server` is kept as a backward-compatible alias.
;; Returns (values port shutdown-proc). The returned port is the requested port
;; (the underlying web-server `serve` does not currently surface the actual
;; listening port when port 0 is requested).
(define (start-server #:port [port 8080] #:public-dir [public-dir "public"])
  (define dispatcher (make-dispatcher public-dir))
  (define shutdown-server (serve #:dispatch dispatcher #:port port #:listen-ip "127.0.0.1"))
  (values port shutdown-server))

;; Backward-compatible alias. Prefer `start-server` in new code.
(define start-dev-server start-server)

(define (stop-server shutdown-proc)
  (shutdown-proc))

(define (make-dispatcher public-dir)
  (lambda (conn req)
    (define resp
      (if (directory-exists? public-dir)
          (serve-static-file public-dir req)
          (make-404-response)))
    (output-response conn resp)))

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
