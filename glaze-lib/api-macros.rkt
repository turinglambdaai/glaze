#lang racket/base

;; define-api-routes: the Racket-macro pay-off layer over the route values.
;;
;;   (define-api-routes api
;;     [(POST "api/counter/bump")
;;      (bump [delta exact-nonnegative-integer? 1])
;;      (begin (bump! delta) (hasheq 'count (unbox count)))]
;;     [(GET "api/items/:id")
;;      (item id)
;;      (hasheq 'id id)])
;;
;; Each clause defines THREE things from one declaration:
;;   1. a Racket procedure (bump delta) — callable directly from Racket,
;;      tests included;
;;   2. a route value in `api` — the JSON body keys become the procedure's
;;      arguments (jsexpr object keys are symbols);
;;   3. a JS client entry — /glaze/api.js derives counterBump(body) from
;;      the same route automatically.
;;
;; Parameter forms:
;;   id                      — required, any value
;;   [id predicate]          — required, checked; a 400 names the parameter
;;   [id predicate default]  — optional, default when the key is absent
;;
;; Body exceptions report as 500 JSON; parameter problems as 400 JSON.

(require (for-syntax racket/base
                     racket/list
                     racket/string
                     syntax/parse)
         "api.rkt")

(provide define-api-routes)

;; Sentinel distinguishing "key absent" from a present #f value.
(define glaze-absent (gensym 'absent))

(define (check-param name get pred default required?)
  (define v (get))
  (cond
    [(eq? v glaze-absent)
     (if required?
         (raise (exn:fail:glaze:bad-param
                 (format "~a: missing" name)
                 (current-continuation-marks)))
         default)]
    [(pred v) v]
    [else
     (raise (exn:fail:glaze:bad-param
             (format "~a: invalid value ~v" name v)
             (current-continuation-marks)))]))

(begin-for-syntax
  ;; id | [id pred] | [id pred default] -> (list id-stx pred-stx default-stx required?-stx)
  (define (param-parts p)
    (syntax-parse p
      [i:id (list #'i #'(lambda (_v) #t) #'#f #'#t)]
      [(i:id pred:expr) (list #'i #'pred #'#f #'#t)]
      [(i:id pred:expr default:expr) (list #'i #'pred #'default #'#f)]))

  ;; ":x" segments of the path, in order — these parameters arrive as
  ;; captured path arguments; everything else comes from the JSON body.
  (define (path-params path-str)
    (for/list ([seg (in-list (string-split (format "~a" (syntax->datum path-str)) "/"))]
               #:when (string-prefix? seg ":"))
      (string->symbol (substring seg 1))))

  (define (expand-clause c)
    (syntax-parse c
      [[(method:id path:str) (proc:id param ...) body ...+]
       (define parts (map param-parts (syntax->list #'(param ...))))
       (define ids (map first parts))
       (define pps (path-params #'path))
       ;; one expression per procedure argument: path captures verbatim,
       ;; body keys through check-param.
       (define arg-exprs
         (for/list ([i (in-list ids)]
                    [pred (in-list (map second parts))]
                    [default (in-list (map third parts))]
                    [req? (in-list (map fourth parts))])
           (define idx (index-of pps (syntax->datum i)))
           (if idx
               #`(list-ref captured-path-args #,idx)
               #`(check-param (quote #,i)
                              (lambda ()
                                (hash-ref req-body (quote #,i) glaze-absent))
                              #,pred
                              #,default
                              #,req?))))
       (with-syntax ([(proc-arg ...) ids]
                     [(arg-e ...) arg-exprs])
         (cons
          #`(define (proc proc-arg ...) body ...)
          #`(method path
                    (lambda (req . captured-path-args)
                      (define req-body (request-json-body req))
                      (proc arg-e ...)))))])))

(define-syntax (define-api-routes stx)
  (syntax-parse stx
    [(_ name:id clause ...)
     (define pairs (map expand-clause (syntax->list #'(clause ...))))
     (with-syntax ([(def ...) (map car pairs)]
                   [(route ...) (map cdr pairs)])
       #'(begin
           def ...
           (define name (list route ...))))]))
