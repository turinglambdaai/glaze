#lang racket/base

;; Pure parts of the glaze install/doctor commands: raco pkg show parsing
;; (both quoted and unquoted link targets), problem detection for legacy
;; links / missing targets / missing root package, sha validation and ref
;; resolution output parsing. The git/raco subprocess flows are exercised
;; live by `raco glaze install` / `raco glaze doctor` itself.

(require rackunit
         racket/list
         racket/string
         glaze-cli/pkg)

;; ---- sha / ref helpers ------------------------------------------------------

(check-true (commit-sha? "ca714caa5eac576e12dbbe0c8daaa2ba7819fb7e"))
(check-true (commit-sha? "CA714CAA5EAC576E12DBBE0C8DAAA2BA7819FB7E"))
(check-false (commit-sha? "main"))
(check-false (commit-sha? "ca714ca"))
(check-false (commit-sha? 42))

;; ---- pkg show parsing ----------------------------------------------------------

(define show-with-quoted-link
  "Installation-wide:\n [none]\nUser-specific for installation \"9.2\":\n Package    Checksum                Source\n glaze                              (link \"C:\\\\Users\\\\dev\\\\glaze-src\")\n")
(define show-with-legacy-link
  "Installation-wide:\n [none]\nUser-specific for installation \"9.2\":\n Package    Checksum                Source\n glaze-lib                          (link \"C:\\\\Users\\\\dev\\\\glaze\\\\glaze-lib\")\n")
(define show-not-installed
  "Installation-wide:\n [none]\nUser-specific for installation \"9.2\":\n Package    Checksum                Source\n [none]\n")

(test-case "quoted link target parses"
  (define parsed (parse-pkg-show "glaze" show-with-quoted-link))
  (check-equal? (first parsed) 'link)
  (check-true (string-contains? (second parsed) "glaze-src")))

(test-case "unquoted raco link shorthand parses"
  (define parsed (parse-pkg-show "glaze-lib" show-with-legacy-link))
  (check-equal? (first parsed) 'link))

(test-case "absent package parses as not-installed"
  (check-equal? (parse-pkg-show "glaze" show-not-installed) '(not-installed)))

;; ---- doctor problem detection ----------------------------------------------------

(define existing-dir (path->string (find-system-path 'temp-dir)))
(define missing-dir
  (path->string (build-path (find-system-path 'temp-dir)
                            "definitely-not-here-9f3a")))

(test-case "healthy table has no problems"
  (check-equal?
   (doctor-problems (hash "glaze" (list 'link existing-dir)))
   '()))

(test-case "legacy links are flagged however healthy their target"
  (define problems
    (doctor-problems (hash "glaze" (list 'link existing-dir)
                             "glaze-lib" (list 'link existing-dir))))
  (check-equal? (length problems) 1)
  (check-true (string-contains? (first problems) "glaze-lib")))

(test-case "link to a deleted checkout is flagged"
  (define problems
    (doctor-problems (hash "glaze" (list 'link missing-dir))))
  (check-equal? (length problems) 1)
  (check-true (string-contains? (first problems) "missing path")))

(test-case "missing root package is flagged"
  (define problems
    (doctor-problems (hash "glaze" '(not-installed)
                             "glaze-lib" '(not-installed))))
  (check-true (ormap (lambda (p) (string-contains? p "no package named")) problems)))

(test-case "non-link installs of legacy names are flagged"
  (define problems
    (doctor-problems (hash "glaze" (list 'link existing-dir)
                             "glaze-doc" (list 'other "glaze-doc 1.0 catalog"))))
  (check-true (ormap (lambda (p) (string-contains? p "glaze-doc")) problems)))
