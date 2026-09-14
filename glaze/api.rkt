#lang racket/base

;; JSON API routes for the frontend <-> Racket bridge.
;;
;; The page calls `fetch("/api/...")`; Racket answers JSON. This is Glaze's
;; answer to Tauri's invoke(): plain HTTP on the same server that serves the
;; frontend, so one code path works in the embedded WebView, in the
;; system-browser fallback, and in dev (curl-able).
;;
;; Routes are ordinary values:
;;
;;   (GET "api/ping" (lambda (req) (hasheq 'pong #t)))
;;   (POST "api/items/:id/bump" (lambda (req id) ...))
;;
;; A handler takes the web-server request followed by the captured :params.
;; It returns a jsexpr (auto-wrapped as a 200 JSON response) or a full
;; response (e.g. via json-response with your own status). request-json-body
;; parses the JSON request body. Handlers that raise produce a 500 JSON
;; error, never a half-written response.

(require json
         racket/list
         racket/string
         net/url
         web-server/http/request-structs
         web-server/http/response-structs)

(provide GET
         POST
         PUT
         DELETE
         route?
         route-handler
         route-method
         route-segments
         param?
         param-id
         (struct-out exn:fail:glaze:bad-param)
         json-response
         api-response
         request-json-body
         error-response
         route-match
         path->segments)

(struct route (method segments handler) #:transparent)
(struct param (id) #:transparent)

;; Raised by define-api-routes argument checking; the server maps it to a
;; 400 (plain exn:fail from a handler stays a 500).
(struct exn:fail:glaze:bad-param exn:fail ())

;; "api/items/:id" -> '("api" "items" (param id))
(define (parse-path path)
  (unless (string? path)
    (raise-argument-error 'api-route "path string with :params" path))
  (for/list ([seg (in-list (string-split path "/" #:trim? #f))])
    (if (string-prefix? seg ":") (param (substring seg 1)) seg)))

(define ((make-route-method method) path handler)
  (unless (procedure? handler)
    (raise-argument-error 'api-route "procedure?" handler))
  (route method (parse-path path) handler))

(define GET (make-route-method 'GET))
(define POST (make-route-method 'POST))
(define PUT (make-route-method 'PUT))
(define DELETE (make-route-method 'DELETE))

;; URL path segments (already filtered of empties) as strings.
(define (path->segments req)
  (map path/param-path (url-path (request-uri req))))

;; Match a request (method symbol + path segments) against a route. Returns
;; the list of captured :param values on match, #f otherwise. All segments
;; must match; ":x" captures a string. The caller applies
;; (apply (route-handler r) req captured).
(define (route-match r method segments)
  (and (eq? (route-method r) method)
       (= (length segments) (length (route-segments r)))
       (let loop ([segs segments] [pats (route-segments r)] [args '()])
         (cond
           [(null? segs) (reverse args)]
           [else
            (define seg (first segs))
            (define pat (first pats))
            (cond
              [(param? pat) (loop (rest segs) (rest pats) (cons seg args))]
              [(string=? seg pat) (loop (rest segs) (rest pats) args)]
              [else #f])]))))

;; jsexpr -> JSON response (200). `json-response` keeps the historical name.
(define (json-response data)
  (api-response data))

(define (api-response data)
  (define json-bytes (string->bytes/utf-8 (jsexpr->string data)))
  (response/full 200 #"OK" (current-seconds)
                 #"application/json; charset=utf-8" '()
                 (list json-bytes)))

;; Parse the request body as JSON. Missing/empty/invalid body -> the empty
;; hash, so optional parameters fall back to their defaults and required
;; ones report a clean 400 instead of an internal type error.
(define (request-json-body req)
  (define raw (request-post-data/raw req))
  (define bs
    (cond
      [(not raw) #""]
      [(eof-object? raw) #""]
      [(bytes? raw) raw]
      [else #""]))
  (define parsed
    (with-handlers ([exn:fail? (lambda (e) (hasheq))])
      (bytes->jsexpr bs)))
  (if (eof-object? parsed) (hasheq) parsed))

(define (error-response status msg)
  (response/full status #"Error" (current-seconds)
                 #"application/json; charset=utf-8" '()
                 (list (string->bytes/utf-8 (jsexpr->string (hasheq 'error msg))))))
