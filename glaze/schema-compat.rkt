#lang racket/base

;; Compatibility baseline for declared command schemas (docs/architecture-
;; 1.0.md step 6): given two schema projections (old, new — the
;; app-schema->app-value renders of /glaze/hello), report whether new is a
;; backward-compatible evolution of old, and list every rule violation.
;;
;; Rules (a client written against old keeps working against new when all
;; hold):
;;   - a command may be ADDED; removing or renaming one is breaking;
;;   - a command's parameter may be ADDED only if optional-with-null
;;     default is expressible — we treat any added parameter as breaking
;;     unless it is optional (its type is optional or Null);
;;   - removing a parameter is breaking; changing a parameter's type is
;;     breaking;
;;   - changing a command's result type is breaking;
;;   - removing a declared error code is breaking; adding is compatible.
;; Record/enum evolution is out of scope for the first cut (commands carry
;; their structure by value here).

(require racket/list
         racket/string
         (only-in keel
                  app-schema-commands
                  Null
                  optional-type?
                  schema-command-name
                  schema-command-parameters
                  schema-command-result
                  schema-parameter-name
                  schema-parameter-type))

(provide schema-compat?
         schema-compat-report
         command-compatible?)

(define (schema-commands v)
  (app-schema-commands v))

(define (command-by-name v name)
  (findf (lambda (c) (equal? (schema-command-name c) name)) (schema-commands v)))

(define (parameter-spec c)
  (for/hash ([p (in-list (schema-command-parameters c))])
    (values (schema-parameter-name p) (schema-parameter-type p))))

;; Two keel type renderings (app-values) match when their serialized forms
;; are equal — deterministic by construction.
(define (type-compatible? a b)
  (equal? a b))

;; An optional parameter is one the client may omit: an explicit
;; optional-type wrapper or Null itself.
(define (optional-ish? t)
  (or (optional-type? t) (eq? t Null)))

(define (command-compatible? old new report)
  (define ok-box (box #t))
  (define (breaking why)
    (set-box! ok-box #f)
    (report why))
  (define old-params (parameter-spec old))
  (define new-params (parameter-spec new))
  (for ([name (in-hash-keys old-params)])
    (unless (hash-has-key? new-params name)
      (breaking (format "removed parameter ~a" name))))
  (for ([(name ntype) (in-hash new-params)])
    (define otype (hash-ref old-params name #f))
    (cond
      [(not otype)
       (unless (optional-ish? ntype)
         (breaking (format "added required parameter ~a" name)))]
      [(not (type-compatible? otype ntype)) (breaking (format "parameter ~a changed type" name))]))
  (unless (type-compatible? (schema-command-result old) (schema-command-result new))
    (breaking "result type changed"))
  (unbox ok-box))

(define (schema-compat-report old new)
  (define report '())
  (define (note why)
    (set! report (cons why report)))
  (define ok
    (for/fold ([ok #t]) ([name (in-list (map schema-command-name (schema-commands old)))])
      (define new-c (command-by-name new name))
      (cond
        [(not new-c)
         (note (format "removed command ~a" name))
         #f]
        [else
         (define old-c (command-by-name old name))
         (and (command-compatible? old-c new-c note) ok)])))
  (values ok (reverse report)))

(define (schema-compat? old new)
  (define-values (ok _) (schema-compat-report old new))
  ok)
