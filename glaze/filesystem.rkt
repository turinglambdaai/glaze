#lang racket/base

;; Capability-ready filesystem plugin. Direct procedures are useful from
;; Racket; make-filesystem-routes exposes them to the embedded frontend.

(require net/base64
         racket/file
         racket/list
         racket/path
         racket/string
         "api.rkt")

(provide fs-read-text
         fs-write-text!
         fs-read-bytes
         fs-write-bytes!
         fs-read-dir
         fs-create-dir!
         fs-remove!
         fs-copy!
         fs-move!
         fs-stat
         fs-exists?
         make-filesystem-routes)

(define (parent-directory path)
  (or (path-only (path->complete-path path)) (current-directory)))

(define (atomic-write path writer)
  (define destination (path->complete-path path))
  (define parent (parent-directory destination))
  (make-directory* parent)
  (define temporary (make-temporary-file ".glaze-write-~a" #f parent))
  (dynamic-wind void
                (lambda ()
                  (call-with-output-file temporary writer #:exists 'truncate/replace)
                  (rename-file-or-directory temporary destination #t))
                (lambda ()
                  (when (or (file-exists? temporary) (link-exists? temporary))
                    (delete-file temporary)))))

(define (fs-read-text path)
  (file->string path #:mode 'text))

(define (fs-write-text! path text)
  (unless (string? text)
    (raise-argument-error 'fs-write-text! "string?" text))
  (atomic-write path (lambda (out) (display text out)))
  (void))

(define (fs-read-bytes path)
  (file->bytes path))

(define (fs-write-bytes! path data)
  (unless (bytes? data)
    (raise-argument-error 'fs-write-bytes! "bytes?" data))
  (atomic-write path (lambda (out) (write-bytes data out)))
  (void))

(define (entry-kind path)
  (case (file-or-directory-type path #f)
    [(directory) "directory"]
    [(directory-link link) "symlink"]
    [(file) "file"]
    [else "other"]))

(define (fs-read-dir path)
  (for/list ([entry (in-list (sort (directory-list path #:build? #t) string<? #:key path->string))])
    (hasheq 'name
            (path->string (file-name-from-path entry))
            'path
            (path->string entry)
            'kind
            (entry-kind entry))))

(define (fs-create-dir! path #:recursive? [recursive? #t])
  ((if recursive? make-directory* make-directory) path)
  (void))

(define (fs-remove! path #:recursive? [recursive? #f])
  (define kind (file-or-directory-type path #f))
  (cond
    [(not kind) (raise-arguments-error 'fs-remove! "path does not exist" "path" path)]
    [(and (eq? kind 'directory) recursive?) (delete-directory/files path)]
    [(memq kind '(directory directory-link)) (delete-directory path)]
    [else (delete-file path)])
  (void))

(define (fs-copy! source destination #:replace? [replace? #f])
  (make-directory* (parent-directory destination))
  (copy-file source destination replace?)
  (void))

(define (fs-move! source destination #:replace? [replace? #f])
  (make-directory* (parent-directory destination))
  (rename-file-or-directory source destination replace?)
  (void))

(define (fs-stat path)
  (define kind (file-or-directory-type path #f))
  (unless kind
    (raise-arguments-error 'fs-stat "path does not exist" "path" path))
  (hasheq 'path
          (path->string (path->complete-path path))
          'kind
          (entry-kind path)
          'size
          (if (eq? kind 'file)
              (file-size path)
              0)
          'modified
          (file-or-directory-modify-seconds path)))

(define (fs-exists? path)
  (and (file-or-directory-type path #f) #t))

(define (bad-parameter message)
  (raise (exn:fail:glaze:bad-param message (current-continuation-marks))))

(define (decode-base64 value)
  (unless (regexp-match? #px"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$" value)
    (bad-parameter "base64: invalid encoded data"))
  (with-handlers ([exn:fail? (lambda (e) (bad-parameter "base64: invalid encoded data"))])
    (base64-decode (string->bytes/utf-8 value))))

(define (body-hash req)
  (define body (request-json-body req))
  (unless (hash? body)
    (bad-parameter "body: expected a JSON object"))
  body)

(define missing (gensym 'missing))

(define (body-ref body key predicate)
  (define value (hash-ref body key missing))
  (cond
    [(eq? value missing) (bad-parameter (format "~a: missing" key))]
    [(predicate value) value]
    [else (bad-parameter (format "~a: invalid value ~v" key value))]))

(define (body-option body key predicate default)
  (define value (hash-ref body key default))
  (if (predicate value)
      value
      (bad-parameter (format "~a: invalid value ~v" key value))))

(define ((single-path-resource key) req)
  (body-ref (body-hash req) key path-string?))

(define ((two-path-resource first-key second-key) req)
  (define body (body-hash req))
  (list (body-ref body first-key path-string?) (body-ref body second-key path-string?)))

(define (ok)
  (hasheq 'ok #t))

(define (make-filesystem-routes #:prefix [prefix "api/fs"])
  (unless (and (string? prefix) (not (string=? prefix "")))
    (raise-argument-error 'make-filesystem-routes "non-empty-string?" prefix))
  (define (endpoint name)
    (string-append (string-trim prefix "/") "/" name))
  (list
   (POST (endpoint "read-text")
         (lambda (req) (hasheq 'text (fs-read-text (body-ref (body-hash req) 'path path-string?))))
         #:permission 'fs:read
         #:resource (single-path-resource 'path))
   (POST (endpoint "write-text")
         (lambda (req)
           (define body (body-hash req))
           (fs-write-text! (body-ref body 'path path-string?) (body-ref body 'text string?))
           (ok))
         #:permission 'fs:write
         #:resource (single-path-resource 'path))
   (POST (endpoint "read-file")
         (lambda (req)
           (define encoded
             (base64-encode (fs-read-bytes (body-ref (body-hash req) 'path path-string?)) #""))
           (hasheq 'base64 (bytes->string/utf-8 encoded)))
         #:permission 'fs:read
         #:resource (single-path-resource 'path))
   (POST (endpoint "write-file")
         (lambda (req)
           (define body (body-hash req))
           (fs-write-bytes! (body-ref body 'path path-string?)
                            (decode-base64 (body-ref body 'base64 string?)))
           (ok))
         #:permission 'fs:write
         #:resource (single-path-resource 'path))
   (POST (endpoint "read-dir")
         (lambda (req) (hasheq 'entries (fs-read-dir (body-ref (body-hash req) 'path path-string?))))
         #:permission 'fs:read
         #:resource (single-path-resource 'path))
   (POST (endpoint "stat")
         (lambda (req) (fs-stat (body-ref (body-hash req) 'path path-string?)))
         #:permission 'fs:read
         #:resource (single-path-resource 'path))
   (POST (endpoint "exists")
         (lambda (req) (hasheq 'exists (fs-exists? (body-ref (body-hash req) 'path path-string?))))
         #:permission 'fs:read
         #:resource (single-path-resource 'path))
   (POST (endpoint "mkdir")
         (lambda (req)
           (define body (body-hash req))
           (fs-create-dir! (body-ref body 'path path-string?)
                           #:recursive? (body-option body 'recursive boolean? #t))
           (ok))
         #:permission 'fs:write
         #:resource (single-path-resource 'path))
   (POST (endpoint "remove")
         (lambda (req)
           (define body (body-hash req))
           (fs-remove! (body-ref body 'path path-string?)
                       #:recursive? (body-option body 'recursive boolean? #f))
           (ok))
         #:permission 'fs:write
         #:resource (single-path-resource 'path))
   (POST (endpoint "copy")
         (lambda (req)
           (define body (body-hash req))
           (fs-copy! (body-ref body 'source path-string?)
                     (body-ref body 'destination path-string?)
                     #:replace? (body-option body 'replace boolean? #f))
           (ok))
         #:permission 'fs:write
         #:resource (two-path-resource 'source 'destination))
   (POST (endpoint "move")
         (lambda (req)
           (define body (body-hash req))
           (fs-move! (body-ref body 'source path-string?)
                     (body-ref body 'destination path-string?)
                     #:replace? (body-option body 'replace boolean? #f))
           (ok))
         #:permission 'fs:write
         #:resource (two-path-resource 'source 'destination))))
