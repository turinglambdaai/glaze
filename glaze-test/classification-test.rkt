#lang racket/base

;; G3-S1 classification guard. docs/api-stability.md carries exactly one
;; tier for every export of the four reviewed layers. This test parses that
;; section and asserts the classification equals the live export surface, so
;; an added, removed, duplicated, or unclassified name fails here instead of
;; silently widening (or rotting) the 1.0 contract. public-api-test.rkt
;; independently pins the raw export sets; the two guards agree only when the
;; docs table matches reality.

(require racket/file
         racket/list
         racket/runtime-path
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

;; One row per table line: | `name` | tier | disposition |
(define (parse-table-line line)
  (define cells
    (for/list ([cell (in-list (string-split line "|"))]
               #:unless (equal? (string-trim cell) ""))
      (string-trim cell)))
  (and (>= (length cells) 2)
       (let* ([name-cell (first cells)]
              [tier (second cells)]
              [name (string-trim name-cell "`")])
         (and (string-prefix? name-cell "`")
              (string-suffix? name-cell "`")
              (not (member name '("Export" "---")))
              (member tier valid-tiers)
              (cons name tier)))))

;; `### \`glaze/window\` — 47 exports` headings scope rows to their module.
(define (parse-classification)
  (define rows (make-hash)) ; module -> mutable list of (name . tier)
  (define current-module #f)
  (for ([line (in-list (string-split section "\n"))])
    (cond
      [(string-prefix? line "### `")
       (define module-name (string-trim (second (string-split line "`")) "`"))
       (set! current-module module-name)]
      [(and current-module (string-prefix? line "|"))
       (define parsed (parse-table-line line))
       (when parsed
         (hash-update! rows current-module (lambda (old) (cons parsed old)) '()))]))
  rows)

(define classification (parse-classification))

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

(define reviewed-modules '(glaze/window glaze/services glaze/distribution glaze/devtools))

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
      (define actual-names (sort (map symbol->string (public-export-names module-path)) string<?))
      ;; set equality in both directions: an unclassified export, a phantom
      ;; row, a rename, or a removal all fail here
      (check-equal? classified-names actual-names "classification equals the live export surface")
      (for ([row (in-list classified-rows)])
        (check-true (and (member (cdr row) valid-tiers) #t)
                    (format "row ~a has a valid tier" (car row)))))))

;; No reviewed-layer export may claim the experimental tier: that tier is
;; reserved for glaze/experimental, which is deliberately outside this table.
(for ([module-path (in-list reviewed-modules)])
  (for ([row (in-list (hash-ref classification (format "~a" module-path) '()))])
    (check-false (equal? (cdr row) "experimental")
                 (format "experimental tier used for ~a in ~a" (car row) module-path))))
