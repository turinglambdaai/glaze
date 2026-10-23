#lang racket/base

;; Direct contract for the portable archive fallback: the archive lands next
;; to (not inside) the distribution directory and contains the dist root.

(require racket/file
         racket/system
         racket/path
         racket/port
         racket/string
         rackunit
         glaze/private/archive-fallback)

(define (quiet thunk)
  (parameterize ([current-error-port (open-output-nowhere)])
    (thunk)))

(define work-root (make-temporary-file "glaze-archive-fallback-~a" 'directory))
(define dist (build-path work-root "FallbackApp-dist"))
(make-directory* dist)
(call-with-output-file (build-path dist "payload.txt")
                       (lambda (out) (display "archive-me" out))
                       #:exists 'replace)

;; ---- tar.gz where tar exists (all CI platforms) ----

(when (find-executable-path "tar" #f)
  (define artifact (quiet (lambda () (archive-directory dist "FallbackApp" "tar.gz"))))
  (check-not-false artifact "tar produced the archive")
  (when artifact
    (check-true (file-exists? (build-path work-root "FallbackApp-dist.tar.gz"))
                "the archive is a sibling of the dist directory")
    (check-true (> (file-size artifact) 0))
    (define listing
      (with-output-to-string
       (lambda () (system* (find-executable-path "tar" #f) "-tf" (path->string artifact)))))
    (check-true (string-contains? listing "FallbackApp-dist/payload.txt")
                "the archive contains the dist root, not a copy of the parent")))

;; ---- zip where a zip tool exists ----

(when (or (find-executable-path "zip" #f)
          (and (eq? (system-type 'os) 'windows) (find-executable-path "powershell.exe" #f)))
  (define artifact (quiet (lambda () (archive-directory dist "FallbackApp" "zip"))))
  (check-not-false artifact "zip produced the archive")
  (when artifact
    (check-true (file-exists? (build-path work-root "FallbackApp-dist.zip")))
    (check-true (> (file-size artifact) 0))))

;; ---- unknown formats degrade to #f instead of raising ----

(check-false (quiet (lambda () (archive-directory dist "FallbackApp" "7z"))))

(delete-directory/files work-root)
