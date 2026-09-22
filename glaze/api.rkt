#lang racket/base

;; JSON API routes for the frontend <-> Racket bridge.
;;
;; The page calls `fetch("/api/...")`; Racket answers JSON. Routes are
;; ordinary values and remain usable in the embedded WebView, tests, and
;; direct HTTP clients.

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

(struct exn:fail:glaze:bad-param exn:fail ())

;; "api/items/:id" -> '("api" "items" (param "id")). Leading/trailing
;; slashes are normalized because users naturally write both "api/x" and
;; "/api/x/". Empty parameter names are rejected at route construction.
(define (parse-path path)
  (unless (string? path)
    (raise-argument-error 'api-route "string?" path))
  (define segments
    (filter non-empty-string? (string-split path "/" #:trim? #f)))
  (when (null? segments)
    (raise-argument-error 'api-route "non-empty route path" path))
  (for/list ([seg (in-list segments)])
    (cond
      [(string-prefix? seg ":")
       (define id (substring seg 1))
       (when (string=? id "")
         (raise-arguments-error 'api-route
                                "path parameter name cannot be empty"
                                "path" path))
       (param id)]
      [(member seg '("." ".."))
       (raise-arguments-error 'api-route
                              "route path cannot contain . or .. segments"
                              "path" path)]
      [else seg])))

(define ((make-route-method method) path handler)
  (unless (procedure? handler)
    (raise-argument-error 'api-route "procedure?" handler))
  (define segments (parse-path path))
  (define capture-count
    (for/sum ([seg (in-list segments)]) (if (param? seg) 1 0)))
  ;; Handlers receive the request plus one argument per :param. Catch an
  ;; accidental arity mismatch while the application starts, not on the first
  ;; customer request.
  (unless (procedure-arity-includes? handler (add1 capture-count))
    (raise-arguments-error 'api-route
                           "handler arity does not accept request plus captured path parameters"
                           "path" path
                           "expected positional arguments" (add1 capture-count)))
  (route method segments handler))

(define GET (make-route-method 'GET))
(define POST (make-route-method 'POST))
(define PUT (make-route-method 'PUT))
(define DELETE (make-route-method 'DELETE))

(define (path->segments req)
  (unless (request? req)
    (raise-argument-error 'path->segments "request?" req))
  (filter non-empty-string?
          (map path/param-path (url-path (request-uri req)))))

(define (route-match r method segments)
  (unless (route? r)
    (raise-argument-error 'route-match "route?" r))
  (unless (symbol? method)
    (raise-argument-error 'route-match "symbol?" method))
  (unless (and (list? segments) (andmap string? segments))
    (raise-argument-error 'route-match "(listof string?)" segments))
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

(define (json-response data)
  (api-response data))

(define (api-response data)
  (unless (jsexpr? data)
    (raise-argument-error 'api-response "jsexpr?" data))
  (define json-bytes (string->bytes/utf-8 (jsexpr->string data)))
  (response/full 200 #"OK" (current-seconds)
                 #"application/json; charset=utf-8" '()
                 (list json-bytes)))

;; Missing/empty/invalid body intentionally yields the empty hash so optional
;; typed-route parameters can use defaults and required parameters report a
;; clean 400 instead of a JSON-parser exception.
(define (request-json-body req)
  (unless (request? req)
    (raise-argument-error 'request-json-body "request?" req))
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
  (unless (and (exact-integer? status) (<= 100 status 599))
    (raise-argument-error 'error-response "exact-integer? in [100, 599]" status))
  (unless (string? msg)
    (raise-argument-error 'error-response "string?" msg))
  (response/full status #"Error" (current-seconds)
                 #"application/json; charset=utf-8" '()
                 (list (string->bytes/utf-8
                        (jsexpr->string (hasheq 'error msg))))))
