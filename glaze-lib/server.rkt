#lang racket/base

(require web-server/web-server
         web-server/http/request-structs
         web-server/http/response-structs
         web-server/http/response
         net/url
         racket/path
         racket/file)

(provide start-dev-server
         stop-server)

(define (start-dev-server #:port [port 8080]
                           #:public-dir [public-dir "public"])
  (define dispatcher (make-dispatcher public-dir))
  (define shutdown-server
    (serve #:dispatch dispatcher
           #:port port
           #:listen-ip "127.0.0.1"))
  (values port shutdown-server))

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
  (define segments (filter (lambda (s) (not (equal? s "")))
                           (map path/param-path uri-path)))
  (define rel (if (null? segments) '("index.html") segments))
  (define candidate (apply build-path dir rel))
  (cond
    [(and (file-exists? candidate)
          (not (directory-exists? candidate)))
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
  (response/full 404 #"Not Found" (current-seconds)
                 #"text/plain; charset=utf-8" '()
                 (list #"Not found")))

(define (path->mime-type p)
  (define ext (path-get-extension p))
  (cond
    [(not ext) #"application/octet-stream"]
    [(member ext '(#".html" #".htm")) #"text/html; charset=utf-8"]
    [(member ext '(#".css")) #"text/css; charset=utf-8"]
    [(member ext '(#".js")) #"application/javascript; charset=utf-8"]
    [(member ext '(#".json")) #"application/json; charset=utf-8"]
    [(member ext '(#".png")) #"image/png"]
    [(member ext '(#".jpg" #".jpeg")) #"image/jpeg"]
    [(member ext '(#".svg")) #"image/svg+xml"]
    [(member ext '(#".ico")) #"image/x-icon"]
    [(member ext '(#".woff2")) #"font/woff2"]
    [(member ext '(#".woff")) #"font/woff"]
    [(member ext '(#".ttf")) #"font/ttf"]
    [else #"application/octet-stream"]))
