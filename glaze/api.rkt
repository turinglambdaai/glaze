#lang racket/base

;; JSON API routes for the frontend <-> Racket bridge.
;;
;; The page calls `fetch("/api/...")`; Racket answers JSON. This is Glaze's
;; answer to Tauri's invoke(): plain HTTP on the same local server that serves
;; the embedded WebView frontend. The endpoints are also easy to exercise from
;; tests and developer tools such as curl.
;;
;; Routes are ordinary values:
;;
;;   (GET "api/ping" (lambda (req) (hasheq 'pong #t)))
;;   (POST "api/items/:id/bump" (lambda (req id) ...))
;;
;; A handler takes the web-server request followed by the captured :params.
;; It returns a jsexpr (auto-wrapped as a 200 JSON response), a full
;; response (e.g. via json-response with your own status), or a streaming
;; response (streaming-response / event-stream-response below). Passing a
;; web-server response? through is part of the contract: the dispatcher
;; normalizes jsexpr -> 200 JSON but hands response values to the connection
;; untouched. request-json-body parses the JSON request body. Handlers that
;; raise produce a 500 JSON error, never a half-written response (streaming
;; is the exception — once the writer has started, the response is on the
;; wire).

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
         route-permission
         route-resource
         param?
         param-id
         (struct-out exn:fail:glaze:bad-param)
         json-response
         api-response
         streaming-response
         event-stream-response
         request-json-body
         error-response
         route-match
         path->segments)

(struct route (method segments handler permission resource) #:transparent)
(struct param (id) #:transparent)

;; Raised by define-api-routes argument checking; the server maps it to a
;; 400 (plain exn:fail from a handler stays a 500).
(struct exn:fail:glaze:bad-param exn:fail ())

;; "api/items/:id" -> '("api" "items" (param id))
(define (parse-path path)
  (unless (string? path)
    (raise-argument-error 'api-route "path string with :params" path))
  (for/list ([seg (in-list (string-split path "/" #:trim? #f))])
    (if (string-prefix? seg ":")
        (param (substring seg 1))
        seg)))

(define ((make-route-method method) path
                                    handler
                                    #:permission [permission #f]
                                    #:resource [resource #f])
  (unless (procedure? handler)
    (raise-argument-error 'api-route "procedure?" handler))
  (when (and permission (not (or (symbol? permission) (string? permission))))
    (raise-argument-error 'api-route "(or/c #f symbol? string?)" permission))
  (when (and resource (not (procedure? resource)))
    (raise-argument-error 'api-route "(or/c #f procedure?)" resource))
  (route method (parse-path path) handler permission resource))

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
       (let loop ([segs segments]
                  [pats (route-segments r)]
                  [args '()])
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
  (response/full 200
                 #"OK"
                 (current-seconds)
                 #"application/json; charset=utf-8"
                 '()
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
  (if (eof-object? parsed)
      (hasheq)
      parsed))

(define (error-response status msg)
  (response/full status
                 #"Error"
                 (current-seconds)
                 #"application/json; charset=utf-8"
                 '()
                 (list (string->bytes/utf-8 (jsexpr->string (hasheq 'error msg))))))

;; ---- streaming responses ----

;; Chunked 200 response: writer is (-> output-port? any) and runs on the
;; connection thread after the status line and headers go out — same
;; mechanism as the built-in /glaze/events SSE endpoint. Write bytes to the
;; port and call (flush-output out) after each chunk that should be
;; delivered immediately; returning from the writer ends the response.
;;
;; Error split: a handler that raises before returning still maps to a 500
;; JSON (nothing is on the wire yet); an exception inside the writer closes
;; the connection mid-stream — wrap your own errors there if truncation is
;; unacceptable. The typical use is proxying a streaming LLM endpoint so
;; tokens reach the page as they arrive (keys stay in Racket, and the page
;; never makes a cross-origin call).
(define (streaming-response writer
                            #:mime [mime #"application/octet-stream"]
                            #:headers [extra-headers '()])
  (unless (procedure? writer)
    (raise-argument-error 'streaming-response "procedure?" writer))
  (response 200 #"OK" (current-seconds) mime extra-headers writer))

;; SSE flavor of streaming-response: sender is (-> (-> (or/c symbol? string?)
;; jsexpr? void?) any); each (send name data) emits one
;; "event: name\ndata: <json>\n\n" frame and flushes. Cache-Control: no-cache
;; is added automatically (supply #:headers to add more).
(define (event-stream-response sender #:headers [extra-headers '()])
  (unless (procedure? sender)
    (raise-argument-error 'event-stream-response "procedure?" sender))
  (streaming-response (lambda (out)
                        (sender (lambda (name data)
                                  (unless (or (symbol? name) (string? name))
                                    (raise-argument-error 'send "(or/c symbol? string?)" name))
                                  (fprintf out "event: ~a\ndata: ~a\n\n" name (jsexpr->string data))
                                  (flush-output out))))
                      #:mime #"text/event-stream"
                      #:headers (cons (header #"Cache-Control" #"no-cache") extra-headers)))
