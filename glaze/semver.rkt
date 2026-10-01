#lang racket/base

(require racket/list
         racket/string)

(provide semver?
         semver-compare
         semver<?
         semver<=?
         semver=?
         semver>=?
         semver>?
         valid-update-channel?
         channel-accepts-version?)

;; SemVer 2.0 precedence. Build metadata never affects ordering;
;; prerelease identifiers use numeric-before-alphanumeric comparison.
(define semver-rx
  #px"^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$")

(define (parse-semver value)
  (and (string? value)
       (let ([match (regexp-match semver-rx value)])
         (and match
              (let ([prerelease (and (list-ref match 4) (string-split (list-ref match 4) "."))])
                (and (or (not prerelease)
                         (for/and ([part (in-list prerelease)])
                           (not (and (regexp-match? #px"^[0-9]+$" part)
                                     (> (string-length part) 1)
                                     (char=? (string-ref part 0) #\0)))))
                     (list (string->number (list-ref match 1))
                           (string->number (list-ref match 2))
                           (string->number (list-ref match 3))
                           prerelease)))))))

(define (semver? value)
  (and (parse-semver value) #t))

(define (identifier-compare left right)
  (define left-number (string->number left))
  (define right-number (string->number right))
  (cond
    [(and left-number right-number)
     (cond
       [(< left-number right-number) -1]
       [(> left-number right-number) 1]
       [else 0])]
    [left-number -1]
    [right-number 1]
    [(string<? left right) -1]
    [(string>? left right) 1]
    [else 0]))

(define (prerelease-compare left right)
  (cond
    [(and (not left) (not right)) 0]
    [(not left) 1]
    [(not right) -1]
    [else
     (let loop ([left left]
                [right right])
       (cond
         [(and (null? left) (null? right)) 0]
         [(null? left) -1]
         [(null? right) 1]
         [else
          (define comparison (identifier-compare (car left) (car right)))
          (if (zero? comparison)
              (loop (cdr left) (cdr right))
              comparison)]))]))

(define (semver-compare left right)
  (define parsed-left (parse-semver left))
  (define parsed-right (parse-semver right))
  (unless parsed-left
    (raise-argument-error 'semver-compare "SemVer 2.0 version string" left))
  (unless parsed-right
    (raise-argument-error 'semver-compare "SemVer 2.0 version string" right))
  (let loop ([left (take parsed-left 3)]
             [right (take parsed-right 3)])
    (cond
      [(null? left) (prerelease-compare (list-ref parsed-left 3) (list-ref parsed-right 3))]
      [(< (car left) (car right)) -1]
      [(> (car left) (car right)) 1]
      [else (loop (cdr left) (cdr right))])))

(define (semver<? left right)
  (= -1 (semver-compare left right)))
(define (semver<=? left right)
  (not (= 1 (semver-compare left right))))
(define (semver=? left right)
  (zero? (semver-compare left right)))
(define (semver>=? left right)
  (not (= -1 (semver-compare left right))))
(define (semver>? left right)
  (= 1 (semver-compare left right)))

(define (valid-update-channel? value)
  (and (memq value '(stable beta dev)) #t))

(define (channel-accepts-version? channel value)
  (unless (valid-update-channel? channel)
    (raise-argument-error 'channel-accepts-version? "'stable, 'beta, or 'dev" channel))
  (define parsed (parse-semver value))
  (unless parsed
    (raise-argument-error 'channel-accepts-version? "SemVer 2.0 version string" value))
  (define prerelease (list-ref parsed 3))
  (case channel
    [(stable) (not prerelease)]
    [(beta)
     (or (not prerelease)
         (for/or ([part (in-list prerelease)])
           (regexp-match? #px"(?i:^beta(?:[.-]|$))" part)))]
    [(dev) #t]))
