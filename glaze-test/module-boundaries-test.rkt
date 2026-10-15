#lang racket/base

;; Public facades are dependency sinks for applications, not dependencies of
;; implementation modules. Importing one facade from another implementation
;; creates cycles and makes later curation impossible.

(require racket/file
         racket/list
         racket/path
         racket/runtime-path
         rackunit)

(define-runtime-path implementation-root-reference "../glaze")
(define implementation-root (simplify-path implementation-root-reference #t))
(define-runtime-path cli-private-root-reference "../glaze-cli/private")
(define cli-private-root (simplify-path cli-private-root-reference #t))

(define facade-import-rx
  #px"\"(?:[.][.]/)*(?:core|window|services|distribution|devtools|experimental)[.]rkt\"")

(define racket-sources
  (find-files (lambda (path)
                (and (file-exists? path)
                     (regexp-match? #rx#"[.]rkt$" (path->bytes path))
                     (not (regexp-match? #rx#"/compiled/" (path->bytes path)))))
              implementation-root))

(for ([source (in-list racket-sources)])
  (check-false (regexp-match? facade-import-rx (file->string source))
               (format "implementation modules must not import a public facade: ~a"
                       (find-relative-path implementation-root source))))

;; Command implementations point inward to shared helpers and framework
;; modules. They must never reach back into the executable dispatcher or its
;; aggregate inspect/package commands, otherwise loading one command re-enables
;; the monolith through a cycle.
(define cli-aggregate-import-rx #px"glaze-cli/(?:cli|inspect|pkg)")
(for ([source (in-list (find-files (lambda (path)
                                    (and (file-exists? path)
                                         (regexp-match? #rx#"[.]rkt$" (path->bytes path))
                                         (not (regexp-match? #rx#"/compiled/" (path->bytes path)))))
                                  cli-private-root))])
  (check-false (regexp-match? cli-aggregate-import-rx (file->string source))
               (format "private CLI command imports an aggregate module: ~a"
                       (find-relative-path cli-private-root source))))
