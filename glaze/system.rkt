#lang racket/base

;; Capability-gated frontend routes for desktop system integrations.

(require racket/path
         racket/os
         racket/string
         "api.rkt"
         "sys/main.rkt")

(provide system-information
         system-hostname
         make-system-routes)

(define missing (gensym 'missing))

(define (bad-parameter message)
  (raise (exn:fail:glaze:bad-param message (current-continuation-marks))))

(define (body-hash req)
  (define body (request-json-body req))
  (unless (hash? body)
    (bad-parameter "body: expected a JSON object"))
  body)

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

(define ((bounded-string? maximum) value)
  (and (string? value) (<= (string-length value) maximum)))

(define (platform-name)
  (case (system-type 'os)
    [(windows) "windows"]
    [(macosx) "macos"]
    [(unix) "linux"]
    [else (symbol->string (system-type 'os))]))

(define (os-type-name)
  (case (system-type 'os)
    [(windows) "Windows_NT"]
    [(macosx) "Darwin"]
    [(unix) "Linux"]
    [else (symbol->string (system-type 'os))]))

(define (system-information)
  (hasheq 'arch
          (symbol->string (system-type 'arch))
          'exeExtension
          (if (eq? (system-type 'os) 'windows) "exe" "")
          'family
          (if (eq? (system-type 'os) 'windows) "windows" "unix")
          'locale
          (system-language+country)
          'osType
          (os-type-name)
          'platform
          (platform-name)
          'version
          (system-type 'machine)))

(define (system-hostname)
  (gethostname))

(define absolute-url-rx #px"^[A-Za-z][A-Za-z0-9+.-]*:[^[:space:]]+$")

(define (absolute-url? value)
  (and ((bounded-string? 8192) value) (regexp-match? absolute-url-rx value) #t))

(define (frontend-path? value)
  (and (string? value) (<= (string-length value) 32768)))

(define (make-system-routes #:prefix [prefix "api/system"])
  (unless (and (string? prefix) (not (string=? prefix "")))
    (raise-argument-error 'make-system-routes "non-empty-string?" prefix))
  (define (endpoint name)
    (string-append (string-trim prefix "/") "/" name))
  (define (path-resource req)
    (body-ref (body-hash req) 'path frontend-path?))
  (define (url-resource req)
    (body-ref (body-hash req) 'url absolute-url?))
  (list (GET (endpoint "clipboard/read")
             (lambda (req) (hasheq 'text (clipboard-get)))
             #:permission 'clipboard:read)
        (POST (endpoint "clipboard/write")
              (lambda (req)
                (hasheq 'ok
                        (clipboard-set!
                         (body-ref (body-hash req) 'text (bounded-string? (* 16 1024 1024))))))
              #:permission 'clipboard:write)
        (POST (endpoint "notification/send")
              (lambda (req)
                (define body (body-hash req))
                (hasheq 'ok
                        (notify! (body-ref body 'title (bounded-string? 512))
                                 (body-option body 'body (bounded-string? (* 16 1024)) "")
                                 #:subtitle (body-option body 'subtitle (bounded-string? 512) ""))))
              #:permission 'notification:send)
        (POST (endpoint "opener/open-path")
              (lambda (req) (hasheq 'ok (open-path (body-ref (body-hash req) 'path frontend-path?))))
              #:permission 'opener:open-path
              #:resource path-resource)
        (POST (endpoint "opener/reveal-path")
              (lambda (req)
                (hasheq 'ok (reveal-path (body-ref (body-hash req) 'path frontend-path?))))
              #:permission 'opener:reveal-path
              #:resource path-resource)
        (POST (endpoint "opener/open-url")
              (lambda (req) (hasheq 'ok (open-path (body-ref (body-hash req) 'url absolute-url?))))
              #:permission 'opener:open-url
              #:resource url-resource)
        (GET (endpoint "os/info") (lambda (req) (system-information)) #:permission 'os:read)
        (GET (endpoint "os/hostname")
             (lambda (req) (hasheq 'hostname (system-hostname)))
             #:permission 'os:hostname)))
