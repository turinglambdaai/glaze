#lang racket/base

;; Documentation is an architecture surface. Keep local links valid and make
;; every top-level guide discoverable from the canonical docs map.

(require racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/string
         rackunit)

(define-runtime-path repository-root-reference "../")
(define repository-root (simplify-path repository-root-reference #t))
(define docs-root (build-path repository-root "docs"))
(define docs-map (build-path docs-root "README.md"))

(define (markdown-file? path)
  (and (file-exists? path) (regexp-match? #rx#"[.]md$" (path->bytes path))))

(define markdown-files
  (append (filter markdown-file? (directory-list repository-root #:build? #t))
          (filter markdown-file? (directory-list docs-root #:build? #t))))

(define (fence-line? line)
  (regexp-match? #px"^[ \t]*(```|~~~)" line))

(define (prose-without-fences text)
  (let loop ([lines (string-split text "\n" #:trim? #f)]
             [inside-fence? #f]
             [visible '()])
    (cond
      [(null? lines) (string-join (reverse visible) "\n")]
      [(fence-line? (car lines)) (loop (cdr lines) (not inside-fence?) visible)]
      [inside-fence? (loop (cdr lines) inside-fence? visible)]
      [else (loop (cdr lines) inside-fence? (cons (car lines) visible))])))

(define markdown-link-rx #px"\\[[^]\r\n]+\\]\\(([^ \t\r\n)]+)")

(define (link-destinations path)
  (regexp-match* markdown-link-rx (prose-without-fences (file->string path)) #:match-select cadr))

(define (external-or-anchor? destination)
  (or (string-prefix? destination "#") (regexp-match? #px"^[A-Za-z][A-Za-z0-9+.-]*:" destination)))

(for* ([source (in-list markdown-files)]
       [destination (in-list (link-destinations source))]
       #:unless (external-or-anchor? destination))
  (define relative (car (string-split destination "#")))
  (define target (build-path (path-only source) relative))
  (check-true (or (file-exists? target) (directory-exists? target))
              (format "broken local Markdown link in ~a: ~a"
                      (find-relative-path repository-root source)
                      destination)))

(define mapped-guides
  (for/list ([destination (in-list (link-destinations docs-map))])
    (car (string-split destination "#"))))

(for ([guide (in-list (filter markdown-file? (directory-list docs-root #:build? #t)))]
      #:unless (equal? guide docs-map))
  (define name (path->string (file-name-from-path guide)))
  (check-not-false (member name mapped-guides)
                   (format "docs/README.md must link top-level guide ~a" name)))
