#lang racket/base

;; GLZ1 protocol fuzzing for the 1.0 evidence gates (docs/1.0-plan.md).
;;
;; Structured, deterministic (fixed-seed xorshift) fuzzing of the GLZ1
;; trust boundary — the decoders a hostile page can reach:
;;
;;   - parse-invoke-envelope: the invoke envelope decoder
;;   - validate-jsexpr: typed-contract validation (result side)
;;
;; The invariant under fuzz is NOT "rejects bad input" alone — it is that
;; every input produces EITHER a well-formed result OR a typed
;; exn:fail:glaze:bridge? (never another escape, never a hang, never a
;; crash), and that the validator's verdict always agrees with the plain
;; predicate on acceptance.

(require rackunit
         racket/list
         racket/random
         racket/string
         glaze/bridge
         glaze/types)

;; ---- deterministic pseudo-random generator (xorshift) ----

(define (make-rng seed)
  (define s (box seed))
  (lambda ()
    (define x (unbox s))
    (define x* (bitwise-xor x (arithmetic-shift x 13)))
    (define x** (bitwise-xor x* (arithmetic-shift x* -7)))
    (define x*** (bitwise-xor x** (arithmetic-shift x** 17)))
    (set-box! s x***)
    (bitwise-and x*** #xFFFFFFFF)))

(define rng (make-rng 20261013))

(define (random-pick xs)
  (list-ref xs (modulo (rng) (length xs))))

(define (random-int lo hi)
  (+ lo (modulo (rng) (+ 1 (- hi lo)))))

;; ---- hostile value generators ----

(define hostile-atoms
  (list null
        #t
        #f
        0
        -1
        1
        -9223372036854775809
        9223372036854775808
        1.5
        +nan.0
        +inf.0
        ""
        (make-string 4096 #\a)
        (string-append "api/" (make-string 64 #\/))
        (string #\u0000 #\u0001 #\u001f)
        "emoji"
        "<script>alert(1)</script>"
        "../../etc/passwd"
        'null
        (list)
        (list 'deep (list 'deeper (list 'deepest (make-list 70 'x))))
        (make-hash)
        (hasheq 'glz 1)
        (hasheq 'glz "1")
        (hasheq 'glz 'null)
        (hasheq 'x (make-vector 8 0))
        (hasheq '__proto__ (hasheq))))

(define (random-hostile-atom)
  (random-pick hostile-atoms))

(define (random-jsexpr depth)
  (define roll (modulo (rng) (if (zero? depth) 5 9)))
  (cond
    [(= roll 0) null]
    [(= roll 1) #t]
    [(= roll 2) #f]
    [(= roll 3) (random-int -1000 1000)]
    [(= roll 4) (random-pick (list "" "abc" (make-string (random-int 0 256) #\j)))]
    [(= roll 5) (build-list (random-int 0 6) (lambda (_) (random-jsexpr (sub1 depth))))]
    [(= roll 6)
     (for/hash ([i (in-range (random-int 0 6))])
       (values (string->symbol (format "k~a" i)) (random-jsexpr (sub1 depth))))]
    [(= roll 7)
     (hasheq 'glz
             glz1-version
             'id
             (format "f~a" (rng))
             'path
             "api/ping"
             'args
             (random-jsexpr (sub1 depth)))]
    [else (random-hostile-atom)]))

;; ---- fuzz invariant runners ----

;; Every input to parse-invoke-envelope must produce either a 4-value
;; result (id path method args) or exn:fail:glaze:bridge?. No other escape.
(define (fuzz-envelope! input)
  (with-handlers ([exn:fail:glaze:bridge? void]
                  [exn:fail? (lambda (e)
                               (fail (format "parse-invoke-envelope escaped with a non-bridge exn: ~a"
                                             (exn-message e))))])
    (define-values (id path method args) (parse-invoke-envelope input))
    (unless (and (string? id) (not (string=? id "")))
      (fail "decoded id violates the non-empty-string contract"))
    (unless (string? path)
      (fail "decoded path violates the string contract"))
    (unless (or (not method) (memq method '(GET POST PUT DELETE)))
      (fail "decoded method outside the closed set"))
    (unless (hash? args)
      (fail "decoded args violate the object contract"))))

;; validate-jsexpr's verdict must always agree with the plain predicate on
;; acceptance, and the violation string must be a string either way.
(define (fuzz-result-validation! value)
  (define-values (ok? why) (validate-jsexpr GString value))
  (unless (boolean? ok?)
    (fail "validate-jsexpr returned a non-boolean ok flag"))
  (unless (or ok? (string? why))
    (fail "violation reason is not a string"))
  (unless (eq? ok? (string? value))
    (fail "validator disagrees with the String predicate")))

;; ---- the fuzz runs ----

(module+ test
  (require rackunit
           rackunit/text-ui)

  (define (check-fuzz name thunk)
    (dynamic-wind void (lambda () (thunk)) void)
    (void))

  (test-case "envelope decoder survives 5000 hostile jsexprs"
    (for ([i (in-range 5000)])
      (fuzz-envelope! (random-jsexpr 3))))

  (test-case "envelope decoder survives 1000 raw hostile atoms"
    (for ([i (in-range 1000)])
      (fuzz-envelope! (random-hostile-atom))))

  (test-case "result validation survives 5000 hostile jsexprs"
    (for ([i (in-range 5000)])
      (fuzz-result-validation! (random-jsexpr 3))))

  (test-case "result validation survives 500 raw hostile atoms"
    (for ([i (in-range 500)])
      (fuzz-result-validation! (random-hostile-atom))))

  (test-case "known-bad envelopes answer their exact typed errors"
    (define (code-of body)
      (with-handlers ([exn:fail:glaze:bridge? exn:fail:glaze:bridge-code]
                      [exn:fail? (lambda (e) (list 'escaped (exn-message e)))])
        (define-values (id path method args) (parse-invoke-envelope body))
        'accepted))
    (check-equal? (code-of (hasheq 'glz 2 'id "x" 'path "p")) 'unsupported-version)
    (check-equal? (code-of (hasheq 'glz 1 'path "p")) 'bad-envelope)
    (check-equal? (code-of (hasheq 'glz 1 'id "" 'path "p")) 'bad-envelope)
    (check-equal? (code-of (hasheq 'glz 1 'id "x")) 'bad-envelope)
    (check-equal? (code-of (hasheq 'glz 1 'id "x" 'path "p" 'method "TRACE")) 'bad-envelope)
    (check-equal? (code-of (hasheq 'glz 1 'id "x" 'path "p" 'args (list 1))) 'bad-envelope)
    (check-equal? (code-of (hasheq 'glz 1 'id "x" 'path "p" 'args (hasheq))) 'accepted)))

(module+ main
  (void))
