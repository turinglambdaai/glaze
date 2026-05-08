#lang racket/base

(require json
         web-server/http/response-structs)

(provide define-api
         json-response)

(define (json-response data)
  (define json-bytes (string->bytes/utf-8 (jsexpr->string data)))
  (response/full 200 #"OK" (current-seconds)
                 #"application/json; charset=utf-8" '()
                 (list json-bytes)))

(require (for-syntax racket/base
                     syntax/parse))

(define-syntax (define-api stx)
  (syntax-parse stx
    [(_ (name:id param:id ...)
        body ...+)
     #'(define (name param ...)
         body ...)]))
