#lang racket/base

;; Pure generation of the temporary entry module used by `raco glaze build`.
;; Keeping source inspection here prevents the build orchestrator from owning
;; application-startup semantics as well as process and filesystem staging.

(require racket/file
         racket/path)

(provide entry-declares-main-submodule?
         entry-module-source
         default-entry-template)

(define (entry-declares-main-submodule? entry-path)
  ;; Read the module form instead of searching its text: a comment or string
  ;; containing `(module+ main ...)` must not make the generated wrapper
  ;; require a submodule that does not exist.
  (define module-datum
    (call-with-input-file entry-path
      (lambda (input)
        (parameterize ([read-accept-reader #t]
                       [current-load-relative-directory (path-only entry-path)])
          (syntax->datum (read-syntax entry-path input))))))
  (define (main-form? form)
    (cond
      [(and (pair? form)
            (memq (car form) '(module module* module+))
            (pair? (cdr form))
            (eq? (cadr form) 'main))
       #t]
      [(and (pair? form)
            (memq (car form) '(begin #%module-begin)))
       (for/or ([nested (in-list (cdr form))])
         (main-form? nested))]
      [else #f]))
  (and (pair? module-datum)
       (eq? (car module-datum) 'module)
       (for/or ([form (in-list (cdddr module-datum))])
         (main-form? form))))

(define (entry-module-source user-entry)
  (define entry-path
    (if (complete-path? user-entry)
        user-entry
        (path->complete-path user-entry)))
  (define entry-filename (path->string (file-name-from-path entry-path)))
  ;; In raco-exe builds `module-declared?` reports #f and `dynamic-require`
  ;; cannot resolve the submodule. Detect an explicit main submodule from the
  ;; parsed source at build time and emit the embedded-safe static require.
  (define has-main-submod? (entry-declares-main-submodule? entry-path))
  (string-append
   "#lang racket/base\n"
   "(require racket/path)\n"
   "(require glaze)\n"
   ";; Prefer the directory holding the packaged executable; inside a macOS\n"
   ";; .app also try ../Resources/public; fall back to the launcher's CWD.\n"
   "(let* ([exe (find-system-path 'run-file)]\n"
   "       [dir (and (path? exe) (path-only exe))]\n"
   "       [candidates (list dir\n"
   "                         (and dir (build-path dir \"..\" \"Resources\")))]\n"
   "       [pick (for/or ([c (in-list candidates)])\n"
   "               (and c (directory-exists? (build-path c \"public\")) c))])\n"
   "  (when (and pick (not (directory-exists? (build-path (current-directory) \"public\"))))\n"
   "    (current-directory pick)))\n"
   ;; Static require: embeds the user module and its full dependency closure
   ;; (raco exe cannot see dynamic-requires), and runs top-level code once.
   (format "(require \"~a\")\n" entry-filename)
   (if has-main-submod?
       (format "(require (submod \"~a\" main))\n" entry-filename)
       "")))

(define (default-entry-template)
  entry-module-source)
