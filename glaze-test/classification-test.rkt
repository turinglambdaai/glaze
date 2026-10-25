#lang racket/base

;; G3 classification guard. docs/api-stability.md carries exactly one tier
;; for every export of the four reviewed layers, plus the deprecated
;; private-shim register left behind by G3-S2. This test parses both and
;; asserts:
;;   - the classified table equals the live export surface, so an added,
;;     removed, duplicated, or unclassified name fails here instead of
;;     silently widening (or rotting) the 1.0 contract;
;;   - every registered shim has actually left its former reviewed layer,
;;     is still reachable through the legacy `glaze` facade (the one
;;     release cycle of compatibility re-exports), and names a canonical
;;     owner. public-api-test.rkt independently pins the raw export sets;
;;     the guards agree only when the docs match reality.

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/runtime-path
         racket/set
         racket/string
         rackunit)

(define-runtime-path repository-root-reference "../")
(define repository-root (simplify-path repository-root-reference #t))

(define doc (file->string (build-path repository-root "docs" "api-stability.md")))

;; ---- parse the marked classification section ----

(define begin-marker "<!-- reviewed-layer-classification:begin -->")
(define end-marker "<!-- reviewed-layer-classification:end -->")

;; Index of the first needle occurrence, or #f. (Kept local: the stdlib's
;; string-contains? is boolean-only and substring needs an offset.)
(define (find-substring hay needle)
  (define limit (- (string-length hay) (string-length needle)))
  (let loop ([i 0])
    (cond
      [(> i limit) #f]
      [(equal? needle (substring hay i (+ i (string-length needle)))) i]
      [else (loop (add1 i))])))

(define section
  (let ([start (find-substring doc begin-marker)]
        [end (find-substring doc end-marker)])
    (check-not-false (and start end) "classification markers present in docs/api-stability.md")
    (if (and start end)
        (substring doc (+ start (string-length begin-marker)) end)
        "")))

(define valid-tiers '("stable" "expert" "private"))

;; One row per table line: | `name` | cell | ... |
(define (parse-table-line line)
  (define cells
    (for/list ([cell (in-list (string-split line "|"))]
               #:unless (equal? (string-trim cell) ""))
      (string-trim cell)))
  (and (>= (length cells) 2)
       (let* ([name-cell (first cells)]
              [name (string-trim name-cell "`")])
         (and (string-prefix? name-cell "`")
              (string-suffix? name-cell "`")
              (not (member name '("Export" "---")))
              (cons name (rest cells))))))

;; `### \`glaze/window\` — 45 exports` headings scope rows to their module;
;; the shim register heading is plain text and scopes its own rows.
(define (heading-name line)
  (if (string-prefix? line "### `")
      (string-trim (second (string-split line "`")) "`")
      (string-trim (substring line 4))))

(define (parse-classification)
  (define rows (make-hash)) ; heading -> mutable list of (name . rest-cells)
  (define current-heading #f)
  (for ([line (in-list (string-split section "\n"))])
    (cond
      [(string-prefix? line "### ") (set! current-heading (heading-name line))]
      [(and current-heading (string-prefix? line "|"))
       (define parsed (parse-table-line line))
       (when parsed
         (hash-update! rows current-heading (lambda (old) (cons parsed old)) '()))]))
  rows)

(define classification (parse-classification))

(define reviewed-modules '(glaze/window glaze/services glaze/distribution glaze/devtools))
(define shim-heading-prefix "Deprecated private-tier shims")

(define shim-heading
  (findf (lambda (k) (string-prefix? k shim-heading-prefix)) (hash-keys classification)))

;; ---- the exact export computation shared with public-api-test.rkt ----

(define (phase-zero-export-names exports)
  (for*/list ([phase-entry (in-list exports)]
              #:when (equal? (car phase-entry) 0)
              [export-entry (in-list (cdr phase-entry))])
    (car export-entry)))

(define (public-export-names module-path)
  (dynamic-require module-path #f)
  (define-values (variable-exports syntax-exports) (module->exports module-path))
  (sort (remove-duplicates (append (phase-zero-export-names variable-exports)
                                   (phase-zero-export-names syntax-exports)))
        symbol<?))

(define live-exports
  (for/hash ([module-path (in-list reviewed-modules)])
    (values module-path (list->set (public-export-names module-path)))))

(for ([module-path (in-list reviewed-modules)])
  (define module-name (format "~a" module-path))
  (define classified-rows (hash-ref classification module-name #f))
  (test-case (format "classification: ~a" module-path)
    (check-true (and classified-rows #t) "the module has a classification table")
    (when classified-rows
      (define classified-names (sort (map car classified-rows) string<?))
      ;; exactly-once: duplicates would silently weaken a tier change
      (check-equal? (length (remove-duplicates classified-names))
                    (length classified-names)
                    "every export is classified exactly once")
      ;; set equality in both directions: an unclassified export, a phantom
      ;; row, a rename, or a removal all fail here
      (check-equal? classified-names
                    (sort (map symbol->string (set->list (hash-ref live-exports module-path)))
                          string<?)
                    "classification equals the live export surface")
      (for ([row (in-list classified-rows)])
        (check-true (and (member (second row) valid-tiers) #t)
                    (format "row ~a has a valid tier" (car row)))))))

;; No reviewed-layer export may claim the experimental tier: that tier is
;; reserved for glaze/experimental, which is deliberately outside this table.
(for ([module-path (in-list reviewed-modules)])
  (for ([row (in-list (hash-ref classification (format "~a" module-path) '()))])
    (check-false (equal? (second row) "experimental")
                 (format "experimental tier used for ~a in ~a" (car row) module-path))))

;; ---- the deprecated private-shim register (G3-S2) ----

;; | `name` | former layer | canonical owner |
(define shims
  (if shim-heading
      (hash-ref classification shim-heading '())
      '()))

(test-case "deprecated private-tier shims"
  (check-true (and shim-heading #t) "the shim register is present")
  (check-true (pair? shims) "the shim register is non-empty")
  ;; the register is a release contract: it shrinks only when the 0.19.0
  ;; removal ships, never silently
  (check-equal? (length shims) 22 "the G3-S2 shim register is fixed until its removal release")
  (define shim-names (map car shims))
  (check-equal? (length (remove-duplicates shim-names))
                (length shim-names)
                "every shim is registered exactly once")
  (define classified-names
    (remove-duplicates (append* (for/list ([m (in-list reviewed-modules)])
                                  (map car (hash-ref classification (format "~a" m) '()))))))
  (check-equal? (filter (lambda (n) (member n classified-names)) shim-names)
                '()
                "shims are disjoint from the classified reviewed-layer surface")
  (for ([row (in-list shims)])
    (match-define (list name former-layer owner) row)
    (define former
      (for/first ([m (in-list reviewed-modules)]
                  #:when (equal? (format "~a" m) former-layer))
        m))
    (check-true (and former #t) (format "shim ~a names a reviewed former layer" name))
    (when former
      (check-false (set-member? (hash-ref live-exports former) (string->symbol name))
                   (format "shim ~a has actually left ~a" name former-layer)))
    (check-false (equal? owner "") (format "shim ~a names a canonical owner" name)))
  ;; the one-release-cycle compatibility window: every shim must stay
  ;; reachable through the legacy facade until its removal release
  (define facade-exports (list->set (public-export-names 'glaze)))
  (for ([name (in-list shim-names)])
    (check-true (set-member? facade-exports (string->symbol name))
                (format "shim ~a is still reachable through the glaze facade" name))))
