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

(define newcomer-guide (build-path docs-root "getting-started.md"))
(define guide-content (file->string newcomer-guide))
(for ([expected (in-list '("raco glaze init" "glaze.rktd"
                                             "glaze-schema.json"
                                             "AGENTS.md"
                                             "verify.rkt"
                                             "module+ main"
                                             "define-api-routes"
                                             "glaze.api.greet"
                                             "raco glaze schema check --json"
                                             "raco glaze verify"
                                             "raco glaze build"))])
  (check-true (string-contains? guide-content expected)
              (format "canonical guide must include ~a" expected)))

(for ([readme (in-list '("README.md" "README.zh-CN.md"))])
  (define path (build-path repository-root readme))
  (define content (file->string path))
  (check-not-false (member "docs/getting-started.md" (link-destinations path))
                   (format "~a must link newcomer guide" readme))
  (check-false (string-contains? content "GLZ1 still runs over loopback HTTP/SSE"))
  (check-false (string-contains? content "GLZ1 仍运行在本机 HTTP/SSE"))
  (check-false (string-contains? content "`run-app` 故意放在顶层")))

(define mapped-guides
  (for/list ([destination (in-list (link-destinations docs-map))])
    (car (string-split destination "#"))))

(for ([guide (in-list (filter markdown-file? (directory-list docs-root #:build? #t)))]
      #:unless (equal? guide docs-map))
  (define name (path->string (file-name-from-path guide)))
  (check-not-false (member name mapped-guides)
                   (format "docs/README.md must link top-level guide ~a" name)))
