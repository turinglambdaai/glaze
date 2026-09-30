#lang racket/base

(require json
         racket/file
         racket/path)

(provide project-report
         run-inspect)

(define (path-string path)
  (path->string (simplify-path path #t)))

(define (entry root relative kind)
  (define absolute (build-path root relative))
  (hash 'path relative
        'absolute (path-string absolute)
        'kind (symbol->string kind)
        'exists (if (eq? kind 'directory)
                    (directory-exists? absolute)
                    (file-exists? absolute))))

(define (command name text mutates)
  (hash 'name name 'command text 'mutates mutates))

(define (project-report [root (current-directory)])
  (define complete (simplify-path (path->complete-path root) #t))
  (hash
   'contract-version 1
   'product "Glaze"
   'principles (list "Human-first" "Agent-native" "Local by design")
   'project-root (path-string complete)
   'application
   (hash 'entry (entry complete "main.rkt" 'file)
         'frontend (entry complete "public" 'directory)
         'verification (entry complete "verify.rkt" 'file)
         'instructions (entry complete "AGENTS.md" 'file))
   'native-ui
   (hash 'model "system WebView in a native desktop window"
         'backend (case (system-type 'os)
                    [(windows) "WebView2"]
                    [(macosx) "WKWebView"]
                    [(unix) "WebKitGTK"]
                    [else "unsupported"])
         'visual-evidence (list "title" "url" "png-screenshot"))
   'generated-paths (list (entry complete "dist" 'directory))
   'commands
   (list (command "inspect" "raco glaze inspect --json" #f)
         (command "diagnose" "raco glaze doctor --json" #f)
         (command "run" "raco glaze dev" #t)
         (command "verify-ui" "raco glaze verify" #t)
         (command "build" "raco glaze build" #t))))

(define (run-inspect #:json? [json? #f])
  (define report (project-report))
  (if json?
      (begin (write-json report) (newline))
      (let ([app (hash-ref report 'application)])
        (printf "Glaze project: ~a\n" (hash-ref report 'project-root))
        (for ([name (in-list '(entry frontend verification instructions))])
          (define item (hash-ref app name))
          (printf "  ~a: ~a [~a]\n"
                  name
                  (hash-ref item 'path)
                  (if (hash-ref item 'exists) "present" "missing")))
        (displayln "  next:")
        (displayln "    raco glaze doctor --json")
        (displayln "    raco glaze verify")))
  0)
