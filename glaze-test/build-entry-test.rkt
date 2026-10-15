#lang racket/base

(require racket/file
         racket/string
         rackunit
         glaze/private/build-entry)

(test-case "entry generation distinguishes real main submodules from text"
  (define temp-dir (make-temporary-file "glaze-build-entry-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define entry (build-path temp-dir "entry.rkt"))
     (define (generate source)
       (call-with-output-file entry (lambda (output) (display source output)) #:exists 'replace)
       (entry-module-source entry))
     (check-false (string-contains?
                   (generate "#lang racket/base\n;; (module+ main (error \"not real\"))\n")
                   "(require (submod \"entry.rkt\" main))"))
     (check-true (string-contains?
                  (generate "#lang racket/base\n(module+ main (displayln \"runs\"))\n")
                  "(require (submod \"entry.rkt\" main))"))
     (check-true (string-contains? ((default-entry-template) entry) "find-system-path 'run-file")))
   (lambda () (delete-directory/files temp-dir))))
