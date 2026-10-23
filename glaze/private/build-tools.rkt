#lang racket/base

;; Shared subprocess and filesystem helpers for the build owners. Staging,
;; signing, and installer-format modules depend on these instead of on the
;; glaze/build orchestrator, keeping the dependency direction pointing inward.

(require racket/file
         racket/system)

(provide find-tool
         run
         find-racket-bin
         delete-tree-quietly!)

;; Returns the first argv[0]-resolvable command among names, or #f.
(define (find-tool . names)
  (for/first ([n (in-list names)]
              #:when (find-executable-path n #f))
    n))

(define (run . args)
  (apply system* args))

;; Locate the raco executable for subprocess calls (exe + distribute live under
;; raco, not racket).
(define (find-racket-bin)
  (or (find-executable-path (if (eq? (system-type 'os) 'windows) "raco.exe" "raco") #f)
      (error 'build-app "could not locate the raco executable")))

(define (delete-tree-quietly! root)
  (with-handlers ([exn:fail? (lambda (e) (void))])
    (delete-directory/files root)))
