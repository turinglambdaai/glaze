#lang racket/base

;; Project scaffold ownership. Keep generated files mutually consistent here:
;; entry point, agent contract, schema configuration/baseline, frontend, and
;; native acceptance script are one versioned template.

(require racket/file
         glaze/private/schema-snapshot)

(provide init-project)

(define (write-file path content)
  (call-with-output-file path (lambda (out) (display content out)) #:exists 'replace))

(define agent-instructions
  #<<AGENTS
# Glaze agent contract

Human-first. Agent-native. Local by design.

Start with `raco glaze inspect --json` and `raco glaze doctor --json`.
Run `raco glaze schema check --json` before merging an API change.

- `main.rkt` owns Racket routes, events, and native-window behavior.
- `glaze.rktd` points schema tooling at the exported route list.
- `glaze-schema.json` is a reviewed release contract; update it explicitly.
- `public/` owns the HTML/CSS/JavaScript interface.
- `verify.rkt` is the non-interactive native UI acceptance check.
- `dist/` is generated output; rebuild it instead of hand-editing it.
- Glaze is GUI-first. Never replace a failed WebView with a browser fallback.
- Preserve loopback-only serving, Host validation, and token protection.

Use `raco glaze dev` for the real application path, `raco glaze verify` for
title/URL/PNG evidence, and `raco glaze build` for distributable output.
AGENTS
  )

(define verification-template
  #<<VERIFY
#lang racket/base

(require racket/file
         glaze)

(define public (build-path (current-directory) "public"))
(define verdicts '())
(define-values (_kind stop)
  (run-app
   #:public-dir public
   #:title "Glaze Verification"
   #:on-ready
   (lambda (wv url)
     (define deadline (+ (current-inexact-milliseconds) 15000))
     (define loaded?
       (let loop ()
         (cond
           [(equal? (webview-title wv) "Glaze App") #t]
           [(>= (current-inexact-milliseconds) deadline) #f]
           [else (sleep 0.1) (loop)])))
     (define shot (and loaded? (webview-capture! wv)))
     (set! verdicts
           (list (cons 'page-loaded loaded?)
                 (cons 'url (equal? (webview-url wv) url))
                 (cons 'capture (and shot (file-exists? shot) (> (file-size shot) 0)))))
     (webview-close wv))))
(stop)
(for ([verdict (in-list verdicts)])
  (printf "[verify] ~a = ~a\n" (car verdict) (cdr verdict)))
(unless (and (pair? verdicts) (andmap cdr verdicts))
  (eprintf "[verify] native UI verification failed\n")
  (exit 1))
(displayln "[verify] ALL PASS")
VERIFY
  )

(define (init-project name)
  (printf "Creating Glaze project: ~a\n" name)
  (make-directory* name)
  (make-directory* (build-path name "public"))
  (write-file (build-path name "main.rkt")
              (string-append "#lang racket/base\n\n"
                             "(require racket/runtime-path\n"
                             "         glaze)\n\n"
                             "(define-runtime-path public \"public\")\n\n"
                             "(define api '())\n"
                             "(provide api)\n\n"
                             "(module+ main\n"
                             "  (run-app #:public-dir public\n"
                             "           #:api api\n"
                             (format "           #:title ~s))\n" name)))
  (write-file
   (build-path name "glaze.rktd")
   "#hasheq((schema-baseline . \"glaze-schema.json\")\n         (schema-binding . api)\n         (schema-module . \"main.rkt\"))\n")
  (write-file (build-path name "glaze-schema.json") (canonical-json-string (schema-snapshot '())))
  (write-file
   (build-path name "public" "index.html")
   #"<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Glaze App</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; background: #0f0f0f; color: #e0e0e0;
    }
    h1 { font-size: 2.5rem; font-weight: 300; }
    p { margin-top: 0.5rem; color: #888; }
    code { background: #1a1a2e; padding: 0.2rem 0.5rem; border-radius: 4px; }
  </style>
</head>
<body>
  <div style=\"text-align:center\">
    <h1>Glaze works!</h1>
    <p>Edit <code>public/index.html</code> to get started.</p>
  </div>
</body>
</html>
")
  (write-file (build-path name "AGENTS.md") agent-instructions)
  (write-file (build-path name "verify.rkt") verification-template)
  (printf "Done! Run:\n  cd ~a\n  racket main.rkt\n\nOr use:\n  cd ~a\n  raco glaze dev\n" name name))
