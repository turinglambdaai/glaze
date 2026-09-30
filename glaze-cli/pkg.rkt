#lang racket/base

;; Package hygiene for glaze consumers: pin a checkout and link it, and
;; diagnose the raco package table.
;;
;; Why this exists: glaze moved from five packages (glaze-lib, glaze-cli,
;; glaze-doc, glaze-test) to one root package named `glaze`. Machines that
;; still carry old links hit cryptic module-path conflicts
;; ("glaze/webview/webview-stub") or unbound requires, and `raco pkg remove
;; glaze-lib` alone leaves the sibling legacy links behind. Every downstream
;; project hand-rolled a clone-and-link script; this module is that script,
;; done once, with the failure modes named out loud.

(require json
         racket/file
         racket/format
         racket/list
         racket/match
         racket/port
         racket/string
         racket/system)

(provide glaze-repo-url
         glaze-pkg-names
         legacy-pkg-names
         commit-sha?
         resolve-ref
         parse-pkg-show
         doctor-problems
         install-command
         doctor-command)

(define glaze-repo-url "https://github.com/turinglambdaai/glaze")
(define legacy-pkg-names '("glaze-lib" "glaze-cli" "glaze-doc" "glaze-test"))
(define glaze-pkg-names (cons "glaze" legacy-pkg-names))

;; ---- pure helpers -------------------------------------------------------------

(define (commit-sha? s)
  (and (string? s) (regexp-match? #px"^[0-9a-fA-F]{40}$" s)))

;; `raco pkg show <name>` output -> one of
;;   (list 'not-installed)
;;   (list 'link <target-string>)
;;   (list 'other <raw-line>)   ; catalog/directory install
(define (parse-pkg-show name text)
  (define lines (string-split text "\n"))
  (cond
    [(ormap (lambda (l) (string-contains? l name)) lines)
     =>
     (lambda (_)
       (cond
         [(regexp-match #px"\\(link\\s+\"([^\"]+)\"" text)
          =>
          (lambda (m) (list 'link (second m)))]
         [(regexp-match #px"\\(link\\s+([^)\\s]+)" text)
          =>
          (lambda (m) (list 'link (second m)))]
         ;; plain `raco pkg show` (no -l) prints the source column without
         ;; parentheses: "glaze    <checksum>    link D:\path\glaze"
         [(regexp-match #px"\\blink\\s+(\\S.*)$" (string-join lines " "))
          =>
          (lambda (m) (list 'link (string-trim (second m))))]
         [else
          (list 'other (string-join (filter (lambda (l) (string-contains? l name)) lines) " "))]))]
    [else (list 'not-installed)]))

;; Parsed entries (name -> parse result) -> list of human-readable problems.
;; An empty list means the table is healthy.
(define (doctor-problems entries)
  (define problems '())
  (define (bad! msg)
    (set! problems (cons msg problems)))
  (for ([(name parsed) (in-hash entries)])
    (match parsed
      [(list 'link target)
       (cond
         [(member name legacy-pkg-names)
          (bad! (format
                 "~a is a legacy pre-rename link (~a); remove it — it conflicts with the root package"
                 name
                 target))]
         [(not (or (directory-exists? target) (file-exists? target)))
          (bad! (format "~a links to a missing path: ~a" name target))])]
      [(list 'other _)
       (when (member name legacy-pkg-names)
         (bad! (format "~a is installed from a legacy package name; remove it" name)))]
      [(list 'not-installed) (void)]))
  (when (equal? (hash-ref entries "glaze" (list 'not-installed)) (list 'not-installed))
    (bad!
     "no package named `glaze` is installed; the collection may still resolve via a non-canonical owner"))
  (reverse problems))

;; ---- subprocess plumbing --------------------------------------------------------

(define (need-exe name)
  (or (find-executable-path name #f) (error 'glaze (format "~a executable not found on PATH" name))))

(define (capture-output . args)
  (define out (open-output-string))
  (define rc
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-nowhere)])
      (apply system*/exit-code args)))
  (values rc (get-output-string out)))

(define (run-quiet! . args)
  (apply system*/exit-code args))

;; All installed packages whose name mentions glaze. Link installs are named
;; after their checkout directory (not the info.rkt name), so real machines
;; accumulate entries like "glaze-src" or "glaze-pinned" — every one of them
;; can own the glaze collection and collide.
(define (discover-glaze-packages)
  (define raco (need-exe "raco"))
  (define-values (rc out) (capture-output raco "pkg" "show" "-a" "-l"))
  (if (zero? rc)
      (for/list ([line (in-list (string-split out "\n"))]
                 #:do [(define m (regexp-match #px"^\\s*([A-Za-z0-9_.-]+)\\*?" line))]
                 #:when (and m (string-contains? (string-downcase (second m)) "glaze")))
        (second m))
      '()))

;; ref (branch/tag) -> full sha, or #f. Raw shas are validated by commit-sha?.
(define (resolve-ref ref)
  (define git (need-exe "git"))
  (define candidates (list (format "refs/heads/~a" ref) (format "refs/tags/~a" ref)))
  (for/or ([candidate (in-list candidates)])
    (define-values (rc out) (capture-output git "ls-remote" glaze-repo-url candidate))
    (and (zero? rc)
         (let ([m (regexp-match #px"^([0-9a-f]{40})\t" (string-trim out))]) (and m (second m))))))

;; ---- install ---------------------------------------------------------------------

;; Usage: raco glaze install <sha|branch|tag> [--dir <path>]
;; DEST precedence: --dir > $GLAZE_SRC_DIR > ~/glaze-src
(define (parse-install-opts rest)
  (let loop ([args rest]
             [dir #f]
             [positional '()])
    (cond
      [(null? args) (values dir (reverse positional))]
      [(and (equal? (car args) "--dir") (pair? (cdr args))) (loop (cddr args) (cadr args) positional)]
      [else (loop (cdr args) dir (cons (car args) positional))])))

(define (remove-glaze-links!)
  (define raco (need-exe "raco"))
  (define names (remove-duplicates (append glaze-pkg-names (discover-glaze-packages))))
  (for ([name (in-list names)])
    (define rc (run-quiet! raco "pkg" "remove" "--force" name))
    (if (zero? rc)
        (printf "  removed existing package link: ~a\n" name)
        (printf "  no existing ~a package\n" name))))

;; Fresh shallow checkout pinned to exactly `sha` (mirrors the classic
;; install-glaze.sh recipe so CI and manual installs agree byte-for-byte).
(define (checkout-at! dest sha)
  (define git (need-exe "git"))
  (when (directory-exists? dest)
    (delete-directory/files dest))
  (make-directory* dest)
  (define (git! . args)
    (unless (zero? (apply run-quiet! git args))
      (error 'install (format "git ~a failed" (string-join args " ")))))
  (git! "-C" (path->string dest) "init" "-q")
  (git! "-C" (path->string dest) "remote" "add" "origin" glaze-repo-url)
  (git! "-C" (path->string dest) "fetch" "-q" "--depth" "1" "origin" sha)
  (git! "-C" (path->string dest) "checkout" "-q" "--detach" "FETCH_HEAD"))

(define (head-sha dest)
  (define git (need-exe "git"))
  (define-values (rc out) (capture-output git "-C" (path->string dest) "rev-parse" "HEAD"))
  (and (zero? rc) (string-trim out)))

(define (install-command rest)
  (define-values (dir positional) (parse-install-opts rest))
  (when (null? positional)
    (error 'install "usage: raco glaze install <sha|branch|tag> [--dir <path>]"))
  (define requested (first positional))
  (define sha
    (cond
      [(commit-sha? requested) (string-downcase requested)]
      [(resolve-ref requested)
       =>
       (lambda (s)
         (printf "Resolved ~a -> ~a\n" requested s)
         s)]
      [else (error 'install (format "unknown glaze ref: ~a (40-hex sha, branch or tag)" requested))]))
  (define dest
    (or dir
        (let ([env (getenv "GLAZE_SRC_DIR")]) (and (non-empty-string? env) env))
        (build-path (find-system-path 'home-dir) "glaze-src")))
  (printf "Installing glaze ~a into ~a\n" sha dest)
  ;; 1. Link hygiene first: legacy links collide on module paths and a plain
  ;;    install refuses with a conflict naming no package.
  (remove-glaze-links!)
  ;; 2. Exact shallow checkout.
  (checkout-at! dest sha)
  (define actual (head-sha dest))
  (unless (equal? actual sha)
    (error 'install (format "checkout mismatch: expected ~a got ~a" sha actual)))
  ;; 3. Link install under the canonical name. Without --name, raco registers
  ;;    the package after the checkout directory ("glaze-src", "glaze-pinned",
  ;;    ...), which is how machines drift into conflicting duplicate owners.
  (define raco (need-exe "raco"))
  (unless (zero? (run-quiet! raco
                             "pkg"
                             "install"
                             "--auto"
                             "--no-docs"
                             "--name"
                             "glaze"
                             "--link"
                             (path->string dest)))
    (error 'install "raco pkg install failed"))
  (printf "Glaze ~a installed (link: ~a)\n" sha dest))

;; ---- doctor ----------------------------------------------------------------------

;; Usage: raco glaze doctor [--fix] [--json]
;; Audits the raco package table for everything that breaks glaze starts:
;; legacy pre-rename links, links to deleted checkouts, and a missing root
;; package. --fix removes the offending links (an install follows).
(define (doctor-entry name)
  (define raco (need-exe "raco"))
  ;; -l prints the full link target in parentheses; the short display
  ;; truncates paths, which would fake "missing path" diagnoses.
  (define-values (_ out) (capture-output raco "pkg" "show" "-l" name))
  (parse-pkg-show name out))

(define (doctor-report entries)
  (for ([(name parsed) (in-hash entries)])
    (match parsed
      [(list 'link target) (printf "  ~a: link -> ~a\n" name target)]
      [(list 'other raw) (printf "  ~a: installed (non-link): ~a\n" name raw)]
      [(list 'not-installed) (printf "  ~a: not installed\n" name)])))

(define (doctor-entry->jsexpr parsed)
  (match parsed
    [(list 'link target)
     (hash 'state
           "link"
           'target
           target
           'target-exists
           (or (directory-exists? target) (file-exists? target)))]
    [(list 'other raw) (hash 'state "installed" 'description raw)]
    [(list 'not-installed) (hash 'state "not-installed")]))

(define (webview-report)
  ;; Load the public API dynamically so `doctor --json` can still explain a
  ;; damaged Glaze installation instead of failing while this CLI module loads.
  (with-handlers ([exn:fail? (lambda (e) (hash 'supported #f 'diagnostic (exn-message e)))])
    (define supported? (dynamic-require 'glaze 'webview-supported?))
    (define diagnostic (dynamic-require 'glaze 'webview-diagnostic))
    (define ok? (supported?))
    (hash 'supported
          ok?
          'diagnostic
          (if ok?
              #f
              (diagnostic)))))

;; Parsed entries -> non-canonical owners of glaze bits: any discovered
;; glaze-related package whose registry name is not exactly "glaze".
(define (non-canonical-glaze-packages)
  (for/list ([name (in-list (discover-glaze-packages))]
             #:when (not (string=? name "glaze")))
    name))

(define (doctor-command rest)
  (define fix? (member "--fix" rest))
  (define json? (member "--json" rest))
  (when (and fix? json?)
    (error 'doctor "--json is read-only and cannot be combined with --fix"))
  (for ([arg (in-list rest)])
    (unless (member arg '("--fix" "--json"))
      (error 'doctor "unexpected argument: ~a" arg)))
  (define raco (need-exe "raco"))
  (define discovered (discover-glaze-packages))
  (define names (remove-duplicates (append glaze-pkg-names discovered)))
  ;; String keys need equal?-based hashing: string literals from different
  ;; modules are distinct objects, so hasheq lookups would silently miss.
  (define entries
    (for/hash ([name (in-list names)])
      (values name (doctor-entry name))))
  (define resolved
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (collection-path "glaze")))
  (define non-canonical (non-canonical-glaze-packages))
  (define problems
    (append
     ;; When a non-canonical owner exists, the missing-`glaze` complaint from
     ;; doctor-problems describes the same situation; drop the duplicate.
     (if (pair? non-canonical)
         (filter (lambda (p) (not (string-prefix? p "no package named"))) (doctor-problems entries))
         (doctor-problems entries))
     (for/list ([name (in-list non-canonical)])
       (format
        "~a owns glaze files under a non-canonical name (link installs are named after their directory); remove it and reinstall with `raco glaze install <rev>`"
        name))
     (if resolved
         '()
         (list "the glaze collection does not resolve — reinstall with: raco glaze install <rev>"))))
  (define webview (webview-report))
  (define all-problems
    (append problems
            (if (hash-ref webview 'supported)
                '()
                (list (format "native WebView unavailable: ~a"
                              (hash-ref webview 'diagnostic "unknown backend error"))))))
  (when json?
    (write-json (hash 'contract-version
                      1
                      'product
                      "Glaze"
                      'usable
                      (null? all-problems)
                      'collection
                      (and resolved (path->string resolved))
                      'packages
                      (for/hash ([(name parsed) (in-hash entries)])
                        (values (string->symbol name) (doctor-entry->jsexpr parsed)))
                      'webview
                      webview
                      'problems
                      all-problems))
    (newline)
    (exit (if (null? all-problems) 0 1)))
  (printf "glaze package table:\n")
  (doctor-report entries)
  (printf "glaze collection resolves to: ~a\n" (or resolved "NOT FOUND"))
  (printf "native WebView: ~a\n"
          (if (hash-ref webview 'supported)
              "available"
              (format "unavailable — ~a" (hash-ref webview 'diagnostic))))
  (cond
    [(null? all-problems) (printf "OK: no glaze package problems found\n")]
    [else
     (printf "Problems:\n")
     (for ([p (in-list all-problems)])
       (printf "  - ~a\n" p))
     (when fix?
       (define broken-link?
         (match (hash-ref entries "glaze" (list 'not-installed))
           [(list 'link t) (not (or (directory-exists? t) (file-exists? t)))]
           [_ #f]))
       (define to-remove
         (append non-canonical
                 (for/list ([n (in-list legacy-pkg-names)]
                            #:when (not (equal? (hash-ref entries n (list 'not-installed))
                                                (list 'not-installed))))
                   n)
                 (if broken-link?
                     (list "glaze")
                     '())))
       (for ([name (in-list (remove-duplicates to-remove))])
         (if (zero? (run-quiet! raco "pkg" "remove" "--force" name))
             (printf "  removed broken link: ~a\n" name)
             (printf "  could not remove ~a\n" name))))
     (unless fix?
       (printf
        "Run `raco glaze doctor --fix` to remove the offending links, then `raco glaze install <rev>`\n"))
     (exit 1)]))
