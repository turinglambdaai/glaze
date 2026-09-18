#lang racket/base

;; Cross-platform packaging regression test.
;;
;; The critical behavior is that an application whose startup code lives in
;; `(module+ main ...)` still executes after build-app/raco distribute. This
;; catches launchers that build successfully but silently exit without running
;; the user's application.

(require racket/file
         racket/path
         racket/system
         glaze/build)

(define work (make-temporary-file "glaze-package-smoke-~a" 'directory))
(define entry (build-path work "main.rkt"))
(define dist (build-path work "dist"))
(define marker (build-path work "ran.txt"))
(define app-name "glaze-package-smoke")

(call-with-output-file
 entry
 (lambda (out)
   (display
    #<<RKT
#lang racket/base
(module+ main
  (define args (current-command-line-arguments))
  (unless (= (vector-length args) 1)
    (error 'package-smoke "expected marker path"))
  (call-with-output-file (vector-ref args 0)
    (lambda (out) (display "module+ main ran" out))
    #:exists 'replace))
RKT
    out))
 #:exists 'replace)

(build-app #:entry entry #:name app-name #:out-dir dist)

(define candidates
  (case (system-type 'os)
    [(windows)
     (list (build-path dist (string-append app-name ".exe"))
           (build-path dist "bin" (string-append app-name ".exe")))]
    [(macosx)
     (list (build-path dist (string-append app-name ".app")
                       "Contents" "MacOS" app-name))]
    [else
     (list (build-path dist app-name)
           (build-path dist "bin" app-name))]))

(define executable
  (for/first ([p (in-list candidates)] #:when (file-exists? p)) p))

(unless executable
  (error 'package-smoke "could not find packaged executable; tried ~a" candidates))

(unless (system* executable (path->string marker))
  (error 'package-smoke "packaged executable failed: ~a" executable))

(unless (and (file-exists? marker)
             (equal? (file->string marker) "module+ main ran"))
  (error 'package-smoke "packaged executable did not run module+ main"))

(delete-directory/files work)
(displayln "package entry smoke test passed")
