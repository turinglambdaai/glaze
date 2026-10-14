#lang racket/base

;; define-api-routes: the Racket-macro pay-off layer over the route values.
;;
;;   (define-api-routes api
;;     [(POST "api/counter/bump")
;;      (bump [delta Int64 1])
;;      (begin (bump! delta) (hasheq 'count (unbox count)))]
;;     [(GET "api/items/:id" #:returns Item)
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
;; The predicate position ALSO accepts a typed descriptor (Int64, String,
;; (glist Item), ...) from glaze/types: the same expression then types the
;; parameter in the route's keel command schema (see route-schema), so the
;; declaration types a parameter and validates it with one expression.
;; Typed routes additionally accept #:returns (a descriptor for the
;; handler's return value) and #:errors (declared error codes). Clause
;; keywords are parsed from the raw tail at expansion time — no
;; syntax-parse keyword machinery, so every keyword is optional with a
;; plain default and none can collide with syntax-parse's clause syntax
;; (one of them, #:result, IS a syntax-parse keyword).
;;
;; Body exceptions report as 500 JSON; parameter problems as 400 JSON.

(require (for-syntax racket/base
                     racket/dict
                     racket/list
                     racket/string
                     syntax/parse)
         "api.rkt"
         "types.rkt")

(provide define-api-routes)

;; Sentinel distinguishing "key absent" from a present #f value.
(define glaze-absent (gensym 'absent))

(define (check-param name get pred default required?)
  ;; The predicate position accepts a plain Racket predicate OR a typed
  ;; descriptor — typed descriptors validate with the same predicate that
  ;; types them in the command schema.
  (define check
    (if (type-descriptor? pred)
        (descriptor-predicate pred)
        pred))
  (define v (get))
  (cond
    [(eq? v glaze-absent)
     (if required?
         (raise (exn:fail:glaze:bad-param (format "~a: missing" name) (current-continuation-marks)))
         default)]
    [(check v) v]
    [else
     (raise (exn:fail:glaze:bad-param (format "~a: invalid value ~v" name v)
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

  ;; Keyword arguments arrive as a raw tail after the path and are parsed
  ;; at expansion time from the datum form — every keyword is optional
  ;; with a plain default and none can collide with syntax-parse's clause
  ;; syntax (one of them, #:result, IS a syntax-parse keyword).
  ;; Values stay as SYNTAX (the clause's own scopes travel with them, so
  ;; descriptors referenced in keyword values resolve in the user module).
  ;; Only the keyword KEYS are unwrapped via syntax-e.
  (define (parse-clause-keywords kws)
    (let loop ([xs kws]
               [acc (hasheq)])
      (cond
        [(or (null? xs) (null? (cdr xs))) acc]
        [else
         (define k (syntax-e (car xs)))
         (unless (keyword? k)
           (raise-arguments-error 'define-api-routes "clause keyword expected" "got" k))
         (loop (cddr xs) (hash-set acc k (cadr xs)))])))

  (define (expand-clause c)
    (syntax-parse c
      [[(method:id path:str kw ...) (proc:id param ...) body ...+]
       (define kws (parse-clause-keywords (syntax->list #'(kw ...))))
       (define permission (dict-ref kws '#:permission #f))
       (define resource (dict-ref kws '#:resource #f))
       (define result (dict-ref kws '#:returns #f))
       (define errors (dict-ref kws '#:errors #'(list)))
       (define explicit-body-types (dict-ref kws '#:body-types '(list)))
       (define parts (map param-parts (syntax->list #'(param ...))))
       (define ids (map first parts))
       (define pps (path-params #'path))
       ;; Typed parameters (descriptor in the predicate position) join the
       ;; route's command schema automatically. The descriptor check happens
       ;; at RUNTIME in make-route-method (descriptors are values, invisible
       ;; to the expander), so every body parameter passes through
       ;; unconditionally as (cons name predicate-expression); explicit
       ;; #:body-types come first.
       (define typed-body-params
         (for/list ([i (in-list ids)]
                    [pred (in-list (map second parts))]
                    #:when (not (member (syntax->datum i) pps)))
           #`(cons (symbol->string (quote #,i)) #,pred)))
       (define body-types #`(append (list #,@typed-body-params) #,explicit-body-types))
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
                              (lambda () (hash-ref req-body (quote #,i) glaze-absent))
                              #,pred
                              #,default
                              #,req?))))
       (with-syntax ([(proc-arg ...) ids]
                     [(arg-e ...) arg-exprs]
                     [body-types body-types]
                     [permission permission]
                     [resource resource]
                     [result result]
                     [errors errors])
         (cons #`(define (proc proc-arg ...)
                   body ...)
               #`(method path
                         (lambda (req . captured-path-args)
                           (define req-body (request-json-body req))
                           (proc arg-e ...))
                         #:permission permission
                         #:resource resource
                         #:body-types body-types
                         #:returns result
                         #:errors errors)))])))
(define-syntax (define-api-routes stx)
  (syntax-parse stx
    [(_ name:id clause ...)
     (define pairs (map expand-clause (syntax->list #'(clause ...))))
     (with-syntax ([(def ...) (map car pairs)]
                   [(route ...) (map cdr pairs)])
       #'(begin
           def ...
           (define name (list route ...))))]))
