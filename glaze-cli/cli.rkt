#lang racket/base

(require racket/match
         racket/file
         glaze/server
         glaze/browser)

(define (init-project name)
  (printf "Creating Glaze project: ~a\n" name)
  (make-directory* name)
  (make-directory* (build-path name "public"))
  (write-file (build-path name "main.rkt")
              (string-append
               "#lang racket/base\n\n"
               "(require glaze)\n\n"
               "(define-values (port server)\n"
               "  (start-dev-server #:public-dir \"public\"))\n\n"
               "(printf \"Glaze app running at http://127.0.0.1:~a\\n\" port)\n"
               "(open-browser (format \"http://127.0.0.1:~a\" port))\n\n"
               "(with-handlers ([exn:break?\n"
               "                 (lambda (e)\n"
               "                   (stop-server server)\n"
               "                   (printf \"Server stopped.\\n\"))])\n"
               "  (sync never-evt))\n"))
  (write-file (build-path name "public" "index.html")
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
  (printf "Done! Run:\n  cd ~a\n  racket main.rkt\n" name))

(define (dev-server)
  (define-values (actual-port server)
    (start-dev-server #:port 8080 #:public-dir "public"))
  (printf "Dev server running at http://127.0.0.1:~a\n" actual-port)
  (open-browser (format "http://127.0.0.1:~a" actual-port))
  (with-handlers ([exn:break?
                   (lambda (e)
                     (stop-server server)
                     (printf "Server stopped.\n"))])
    (sync never-evt)))

(define (print-help)
  (displayln "Usage: raco glaze <command> [args]")
  (displayln "")
  (displayln "Commands:")
  (displayln "  init <name>   Create a new Glaze project")
  (displayln "  dev           Start dev server with auto-open browser")
  (displayln "  help          Show this help"))

(define (write-file path content)
  (call-with-output-file path
    (lambda (out) (display content out))
    #:exists 'replace))

;; Dispatch CLI commands
(define args (vector->list (current-command-line-arguments)))
(cond
  [(null? args)
   (print-help)]
  [else
   (define cmd (car args))
   (define rest (cdr args))
   (match cmd
     ["init"
      (init-project (if (null? rest) "myapp" (car rest)))]
     ["dev"
      (dev-server)]
     ["help"
      (print-help)]
     [_
      (printf "Unknown command: ~a\n" cmd)
      (print-help)])])
