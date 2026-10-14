#lang racket/base

;; Typed command declarations (docs/architecture-1.0.md step 6, Tauri
;; command+TS parity). Keel stays the canonical schema; this module adds the
;; three things a Racket-side declaration needs on top of it:
;;
;;   1. TYPE DESCRIPTORS usable in route declarations anywhere a predicate
;;      is accepted — `Int64`, `String`, `(glist Item)`, `(goptional
;;      GFloat64)` — each bundling a keel type with a jsexpr predicate, so
;;      `define-api-routes` validates a parameter with the same expression
;;      that types it in the schema;
;;   2. a WIRE VALIDATOR that checks a decoded jsexpr value against a
;;      descriptor (the invoke pipeline reports violations as typed
;;      invalid-args errors);
;;   3. a TYPESCRIPT mapping that renders declared records, enums, and
;;      commands as a .d.ts client declaration (served at /glaze/api.d.ts
;;      on every transport).
;;
;; Wire conventions: `Null` is JSON null; `Bytes` is a base64 string;
;; unknown object keys are tolerated so newer clients keep working against
;; older apps. Named types (grecord/genum) are referenced by value — using
;; `Item` inside another declaration IS the reference.

(require json
         racket/format
         racket/list
         racket/string
         (only-in keel
                  Bool
                  Bytes
                  Float64
                  Int64
                  Null
                  String
                  list-type
                  list-type-element
                  list-type?
                  map-type
                  map-type-value
                  map-type?
                  optional-type
                  optional-type-element
                  optional-type?
                  reference-type
                  reference-type?
                  reference-type-name
                  scalar-type
                  scalar-type-name
                  scalar-type?
                  schema-command
                  schema-command-error-codes
                  schema-command-name
                  schema-command-parameters
                  schema-command-result
                  schema-enum
                  schema-enum-cases
                  schema-enum-name
                  schema-field
                  schema-parameter-name
                  schema-parameter-type
                  schema-record
                  schema-record-name
                  Value))

(provide (struct-out gtype)
         grecord
         grecord?
         grecord-name
         grecord-fields
         grecord-keel-record
         genum
         genum?
         genum-name
         genum-cases
         genum-keel-enum
         type-descriptor?
         type-descriptor-keel
         descriptor-predicate
         GNull
         GBool
         GInt64
         GFloat64
         GString
         GBytes
         GValue
         glist
         goptional
         gmap
         validate-type
         validate-jsexpr
         type->ts
         command-named-types
         collect-named-types
         generate-ts-declarations)

;; ---- descriptors ----

;; A scalar/compound descriptor: the keel type for the schema projection
;; plus the jsexpr predicate the parameter layer checks.
(struct gtype (keel pred) #:transparent)

;; Named application types: declared once, referenced by value. `fields`
;; is an ordered (listof (cons field-name descriptor)).
(struct glz-record (name fields keel-record) #:transparent #:constructor-name make-glz-record)
(struct glz-enum (name cases keel-enum) #:transparent #:constructor-name make-glz-enum)

(define (type-descriptor? v)
  (or (gtype? v) (glz-record? v) (glz-enum? v)))

(define (type-descriptor-keel v)
  (descriptor-keel-type v))

(define (grecord? v)
  (glz-record? v))
(define (grecord-name v)
  (glz-record-name v))
(define (grecord-fields v)
  (glz-record-fields v))
(define (grecord-keel-record v)
  (glz-record-keel-record v))
(define (genum? v)
  (glz-enum? v))
(define (genum-name v)
  (glz-enum-name v))
(define (genum-cases v)
  (glz-enum-cases v))
(define (genum-keel-enum v)
  (glz-enum-keel-enum v))

(define (descriptor-predicate v)
  (cond
    [(gtype? v) (gtype-pred v)]
    [(glz-record? v) (lambda (x) (boolean? (validate-type v x)))]
    [(glz-enum? v) (lambda (x) (boolean? (validate-type v x)))]
    [else (raise-argument-error 'descriptor-predicate "type-descriptor?" v)]))

;; ---- scalars ----

(define (exact-int64? v)
  (and (exact-integer? v) (>= v -9223372036854775808) (<= v 9223372036854775807)))

;; JSON numbers arrive as exact integers or finite floats; `rational?`
;; excludes NaN and infinities that other producers might smuggle in.
(define (finite-real? v)
  (and (real? v) (rational? v)))

(define base64-rx #px"^[A-Za-z0-9+/]*={0,2}$")

(define GString (gtype String string?))
(define GInt64 (gtype Int64 exact-int64?))
(define GFloat64 (gtype Float64 finite-real?))
(define GBool (gtype Bool boolean?))
;; JSON null decodes to the 'null symbol in Racket's jsexpr world.
(define GNull (gtype Null (lambda (v) (eq? v 'null))))
;; Base64 text — bytes never appear inside a jsexpr payload.
(define GBytes (gtype Bytes (lambda (v) (and (string? v) (regexp-match? base64-rx v)))))
;; Any jsexpr value; escapes all further validation (the escape hatch).
(define GValue (gtype Value jsexpr?))

;; ---- compounds ----

(define (require-descriptor! who v)
  (unless (type-descriptor? v)
    (raise-argument-error who "type-descriptor?" v)))

;; Keel's type universe references named types (records/enums) by name —
;; the named values themselves live at the schema layer. Descriptors map
;; accordingly: scalars/compounds keep their keel type, named types become
;; reference-types.
(define (descriptor-keel-type d)
  (cond
    [(gtype? d) (gtype-keel d)]
    [(glz-record? d) (reference-type (glz-record-name d))]
    [(glz-enum? d) (reference-type (glz-enum-name d))]
    [else (raise-argument-error 'descriptor-keel-type "type-descriptor?" d)]))

(define (glist element)
  (require-descriptor! 'glist element)
  (gtype (list-type (descriptor-keel-type element))
         (let ([pred (descriptor-predicate element)]) (lambda (v) (and (list? v) (andmap pred v))))))

(define (goptional element)
  (require-descriptor! 'goptional element)
  (gtype (optional-type (descriptor-keel-type element))
         (let ([pred (descriptor-predicate element)]) (lambda (v) (or (eq? v 'null) (pred v))))))

(define (gmap value)
  (require-descriptor! 'gmap value)
  (gtype (map-type (descriptor-keel-type value))
         (let ([pred (descriptor-predicate value)])
           (lambda (v)
             (and (hash? v)
                  (for/and ([(k x) (in-hash v)])
                    (and (string? k) (pred x))))))))

(define (name-string name)
  (if (symbol? name)
      (symbol->string name)
      name))

;; (grecord Item "id" GInt64 "name" GString) — flat name/descriptor pairs
;; (a declaration macro may also build these pairs). Fields keep
;; declaration order: interface rendering and validation are both
;; order-stable.
(define (grecord name . field-parts)
  (unless (or (symbol? name) (string? name))
    (raise-argument-error 'grecord "(or/c symbol? string?)" name))
  (unless (and (list? field-parts) (even? (length field-parts)) (>= (length field-parts) 2))
    (raise-argument-error 'grecord "(list name descriptor ...)" field-parts))
  (define field-list
    (let loop ([parts field-parts]
               [acc '()])
      (cond
        [(null? parts) (reverse acc)]
        [else
         (define fname (name-string (first parts)))
         (define d (second parts))
         (unless (type-descriptor? d)
           (raise-argument-error 'grecord "type-descriptor?" d))
         (loop (list-tail parts 2) (cons (cons fname d) acc))])))
  (make-glz-record (name-string name)
                   field-list
                   (schema-record (name-string name)
                                  (for/list ([f (in-list field-list)])
                                    (schema-field (car f) (descriptor-keel-type (cdr f)))))))

(define (genum name . cases)
  (unless (or (symbol? name) (string? name))
    (raise-argument-error 'genum "(or/c symbol? string?)" name))
  (for ([c (in-list cases)])
    (unless (or (symbol? c) (string? c))
      (raise-argument-error 'genum "(listof (or/c symbol? string?))" c)))
  (make-glz-enum (name-string name)
                 (map name-string cases)
                 (schema-enum (name-string name) (map name-string cases))))

;; ---- wire validation ----

;; validate-type: descriptor × jsexpr → #t when the value conforms, or a
;; violation string naming the offending path.
(define (keel-scalar-pred name)
  (case name
    [(String) string?]
    [(Int64) exact-int64?]
    [(Float64) finite-real?]
    [(Bool) boolean?]
    [(Null) (lambda (v) (eq? v 'null))]
    [(Bytes) (lambda (v) (and (string? v) (regexp-match? base64-rx v)))]
    [(Value) jsexpr?]
    [else (lambda (v) #t)]))

(define (validate-type d v [path ""])
  (define (violate why)
    (if (string=? path "")
        why
        (format "~a: ~a" path why)))
  (cond
    ;; bare keel types (schema-command parameters/results carry these
    ;; directly). reference-types validate permissively here: the named
    ;; values live in the declaring module, whose parameter layer already
    ;; checked them with the full descriptor predicate.
    [(scalar-type? d)
     (if ((keel-scalar-pred (scalar-type-name d)) v)
         #t
         (violate "invalid value"))]
    [(list-type? d)
     (cond
       [(not (list? v)) (violate "expected a list")]
       [else
        (define first-bad
          (for/or ([x (in-list v)]
                   [i (in-naturals)])
            (define r (validate-type (list-type-element d) x (format "~a[~a]" path i)))
            (and (not (eq? r #t)) r)))
        (or first-bad #t)])]
    [(optional-type? d)
     (if (eq? v 'null)
         #t
         (validate-type (optional-type-element d) v path))]
    [(map-type? d)
     (cond
       [(not (hash? v)) (violate "expected an object")]
       [else
        (define first-bad
          (for/or ([(k x) (in-hash v)])
            (define r (validate-type (map-type-value d) x path))
            (and (not (eq? r #t)) r)))
        (or first-bad #t)])]
    [(reference-type? d) #t]
    [(gtype? d)
     (if ((gtype-pred d) v)
         #t
         (violate "invalid value"))]
    [(glz-record? d)
     (cond
       [(not (hash? v)) (violate "expected an object")]
       [else
        (define first-bad
          (for/or ([f (in-list (glz-record-fields d))])
            (define fname (car f))
            (define fpath
              (if (string=? path "")
                  fname
                  (string-append path "." fname)))
            ;; jsexpr object keys are symbols in Racket's JSON world; accept
            ;; string keys too for producers that hand-build maps.
            (define fv (hash-ref v (string->symbol fname) (hash-ref v fname 'null)))
            (define result (validate-type (cdr f) fv fpath))
            (and (not (eq? result #t)) result)))
        (or first-bad #t)])]
    [(glz-enum? d)
     (if (and (string? v) (member v (glz-enum-cases d)))
         #t
         (violate (format "expected one of ~a" (string-join (glz-enum-cases d) ", "))))]
    [else (violate "not a type descriptor")]))

;; Public form: (values ok? violation) so callers branch without string
;; sniffing.
(define (validate-jsexpr d v)
  (define result (validate-type d v ""))
  (values (eq? result #t) (and (not (eq? result #t)) result)))

;; ---- TypeScript mapping ----

(define (keel-scalar->ts name)
  (case name
    [(String) "string"]
    [(Int64) "number"]
    [(Float64) "number"]
    [(Bool) "boolean"]
    [(Null) "null"]
    [(Bytes) "string /* base64 */"]
    [(Value) "unknown"]
    [(Unit Error) "null"]
    [else "unknown"]))

;; Renders one descriptor as a TS type expression. `named` carries the
;; record/enum names that will be declared at top level — references to
;; them print by name.
(define (type->ts d [named '()])
  (cond
    ;; bare keel types (schema-command parameters/results carry these
    ;; directly) and descriptors share one rendering.
    [(reference-type? d) (reference-type-name d)]
    [(scalar-type? d) (keel-scalar->ts (scalar-type-name d))]
    [(list-type? d) (string-append (type->ts (list-type-element d) named) "[]")]
    [(optional-type? d) (string-append (type->ts (optional-type-element d) named) " | null")]
    [(map-type? d) (format "{{ [key: string]: ~a }}" (type->ts (map-type-value d) named))]
    [(gtype? d)
     (define k (gtype-keel d))
     (cond
       [(scalar-type? k) (keel-scalar->ts (scalar-type-name k))]
       [(list-type? k) (string-append (type->ts (list-type-element k) named) "[]")]
       [(optional-type? k) (string-append (type->ts (optional-type-element k) named) " | null")]
       [(map-type? k) (format "{{ [key: string]: ~a }}" (type->ts (map-type-value k) named))]
       [else "unknown"])]
    [(glz-record? d)
     (define name (glz-record-name d))
     (if (member name named)
         name
         (format "{ ~a }"
                 (string-join (for/list ([f (in-list (glz-record-fields d))])
                                (format "~a: ~a" (car f) (type->ts (cdr f) named)))
                              "; ")))]
    [(glz-enum? d)
     (define name (glz-enum-name d))
     (if (member name named)
         name
         (format "~a"
                 (string-join (for/list ([c (in-list (glz-enum-cases d))])
                                (format "~s" c))
                              " | ")))]
    [else "unknown"]))

; Walk a descriptor collecting every named type it references (by value),
;; deduplicated by name, returned as a flat LIST of descriptors.
(define (command-named-types command)
  (append-map (lambda (t) (collect-named-types t))
              (append (map schema-parameter-type (schema-command-parameters command))
                      (list (schema-command-result command)))))

;; Renders the whole .d.ts: named types first (interfaces + unions), then
;; one namespaced function per command. Commands arrive as keel
;; schema-commands with GLZ1 command names (the generated client names).
(define (generate-ts-declarations commands named-types)
  (define named
    (append (for/list ([r (in-list named-types)]
                       #:when (glz-record? r))
              (glz-record-name r))
            (for/list ([e (in-list named-types)]
                       #:when (glz-enum? e))
              (glz-enum-name e))))
  (define extra-named
    (remove-duplicates (append-map command-named-types commands)
                       #:key (lambda (d)
                               (if (glz-record? d)
                                   (glz-record-name d)
                                   (glz-enum-name d)))))
  (define all-named
    (for/list ([d (in-list (append named-types extra-named))])
      d))
  (define all-named-names
    (for/list ([d (in-list all-named)])
      (if (glz-record? d)
          (glz-record-name d)
          (glz-enum-name d))))
  (string-append
   "/* Generated by glaze — do not edit. Types come from the app's declared\n"
   "   command schema (keel); served at /glaze/api.d.ts. */\n"
   (string-append
    "declare namespace glaze.types {\n"
    (string-join
     (for/list ([d (in-list all-named)])
       (cond
         [(glz-enum? d)
          (format "  export type ~a = ~a;\n"
                  (glz-enum-name d)
                  (string-join (for/list ([c (in-list (glz-enum-cases d))])
                                 (format "~s" c))
                               " | "))]
         [else
          (format "  export interface ~a {\n~a  }\n"
                  (glz-record-name d)
                  (string-join (for/list ([f (in-list (glz-record-fields d))])
                                 (format "    ~a: ~a;\n" (car f) (type->ts (cdr f) all-named-names)))
                               ""))]))
     "\n")
    "}\n\n")
   (string-join (for/list ([command (in-list commands)])
                  (define name (schema-command-name command))
                  (define ts-name (js-camel-safe name))
                  (define args (schema-command-parameters command))
                  (define args-ts
                    (if (null? args)
                        ""
                        (format "args: { ~a }"
                                (string-join (for/list ([p (in-list args)])
                                               (format "~a: ~a"
                                                       (schema-parameter-name p)
                                                       (type->ts (schema-parameter-type p)
                                                                 all-named-names)))
                                             "; "))))
                  (format "declare function glaze.~a(~a): Promise<~a>;\n"
                          ts-name
                          args-ts
                          (type->ts (schema-command-result command) all-named-names)))
                "\n")))

;; GLZ1 command names are kebab-case ("api-items-get"); TS function names
;; camel-case them ("apiItemsGet") exactly like the generated JS client.
(define (js-camel-safe name)
  (define parts (filter non-empty-string? (string-split name "-")))
  (define head
    (cond
      [(null? parts) "command"]
      [(regexp-match? #rx"^[0-9]" (first parts)) (string-append "_" (first parts))]
      [else (first parts)]))
  (apply string-append
         head
         (for/list ([p (in-list (rest parts))])
           (if (zero? (string-length p))
               ""
               (string-append
                (string-upcase (substring p 0 1))
                (substring
                 p
                 1)))))) ; Walk a descriptor collecting every named type it references (by value).
;; Returns a flat list of descriptors (possibly with duplicates — callers
;; deduplicate by name). Self-recursive records are not expressible at the
;; value level (each grecord references previously defined ones), so plain
;; recursion terminates.
(define (collect-named-types d)
  (cond
    [(glz-record? d)
     (cons d (apply append (map (lambda (f) (collect-named-types (cdr f))) (glz-record-fields d))))]
    [(glz-enum? d) (list d)]
    [(gtype? d)
     (define k (gtype-keel d))
     (cond
       [(list-type? k) (collect-named-types (list-type-element k))]
       [(optional-type? k) (collect-named-types (optional-type-element k))]
       [(map-type? k) (collect-named-types (map-type-value k))]
       ;; a bare reference points at a named type whose own descriptor is
       ;; collected at its declaration site
       [else '()])]
    [else '()]))
