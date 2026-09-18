#lang racket/base

;; Update checking: fetch a small version manifest over HTTP(S), compare with
;; the running version, and report availability. Download/replacement remains a
;; distribution-specific application decision.

(require json
         racket/list
         racket/port
         racket/string
         racket/system
         net/http-client)

(provide check-update
         newer-version?
         verify-file-sha256)

(define manifest-timeout-secs 5)
(define max-manifest-bytes (* 1024 1024))
(define numeric-version-rx #px"^[0-9]+(?:[.][0-9]+)*$")
(define sha256-rx #px"^[0-9a-fA-F]{64}$")

(define (numeric-version? v)
  (and (string? v) (regexp-match? numeric-version-rx v)))

;; Timeout work under a private custodian so timeout also tears down the
;; socket/worker instead of leaving a blocked background thread behind.
(define (call-with-timeout secs thunk)
  (define cust (make-custodian))
  (define ch (make-channel))
  (parameterize ([current-custodian cust])
    (thread
     (lambda ()
       (define result
         (with-handlers ([exn:fail? (lambda (e) #f)])
           (thunk)))
       (channel-put ch result))))
  (define result (sync/timeout secs ch))
  (custodian-shutdown-all cust)
  result)

(define (status-success? status-line)
  (and (bytes? status-line)
       (regexp-match? #px#"^HTTP/[0-9.]+ 2[0-9][0-9](?: |$)" status-line)))

;; Network input ports are allowed to return short reads before EOF. Read in
;; chunks until the response ends or exceeds the hard size limit.
(define (read-limited-body in)
  (define out (open-output-bytes))
  (let loop ([total 0])
    (define chunk (read-bytes 65536 in))
    (cond
      [(eof-object? chunk) (get-output-bytes out)]
      [else
       (define next (+ total (bytes-length chunk)))
       (cond
         [(> next max-manifest-bytes) #f]
         [else
          (write-bytes chunk out)
          (loop next)])])))

;; -> body bytes or #f. Only HTTP(S) is accepted. TLS errors, non-2xx
;; responses, malformed authorities, oversized manifests and timeouts all
;; safely mean "no update information".
(define (fetch-manifest url)
  (and (string? url)
       (call-with-timeout
        manifest-timeout-secs
        (lambda ()
          (define m
            (regexp-match #rx"^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/]+)(/.*)?$" url))
          (unless m (error 'check-update "bad manifest url"))
          (define scheme (string-downcase (list-ref m 1)))
          (unless (member scheme '("http" "https"))
            (error 'check-update "manifest URL must use http or https"))
          (define authority (list-ref m 2))
          (define path (or (list-ref m 3) "/"))
          (define ssl? (string=? scheme "https"))
          (define hp
            (or (regexp-match #px"^\\[([^]]+)\\](?::([0-9]+))?$" authority)
                (regexp-match #px"^([^:]+)(?::([0-9]+))?$" authority)))
          (unless hp (error 'check-update "bad manifest authority"))
          (define host (second hp))
          (define explicit-port (and (third hp) (string->number (third hp))))
          (define port (or explicit-port (if ssl? 443 80)))
          (unless (and (exact-integer? port) (<= 1 port 65535))
            (error 'check-update "bad manifest port"))
          (when ssl?
            (dynamic-require 'openssl 'ssl-connect #f))
          (define-values (status _headers in)
            (http-sendrecv host path #:port port #:ssl? (if ssl? 'auto #f)))
          (dynamic-wind
            void
            (lambda ()
              (and (status-success? status)
                   (read-limited-body in)))
            (lambda () (close-input-port in)))))))

(define (check-update manifest-url #:current-version [current "0.0.0"])
  (unless (string? manifest-url)
    (raise-argument-error 'check-update "string?" manifest-url))
  (unless (numeric-version? current)
    (raise-argument-error 'check-update "numeric dotted version string" current))
  (define body (fetch-manifest manifest-url))
  (and body
       (let ()
         (define data
           (with-handlers ([exn:fail? (lambda (e) #f)])
             (bytes->jsexpr body)))
         (and (hash? data)
              (let ([v (hash-ref data 'version #f)]
                    [u (hash-ref data 'url #f)]
                    [notes (hash-ref data 'notes #f)]
                    [sha (hash-ref data 'sha256 #f)])
                ;; A malformed remote manifest is untrusted input: ignore it
                ;; rather than raising inside the application.
                (and (numeric-version? v)
                     (string? u)
                     (non-empty-string? u)
                     (or (not notes) (string? notes))
                     (or (not sha)
                         (and (string? sha) (regexp-match? sha256-rx sha)))
                     (newer-version? v current)
                     (hasheq 'version v
                             'url u
                             'notes notes
                             'sha256 sha)))))))

;; True when the file has the expected SHA-256 digest. #f means verification
;; failed or could not be performed; callers must never interpret #f as safe.
(define (verify-file-sha256 path expected-hex)
  (define exe (find-executable-path "openssl" #f))
  (define p
    (cond
      [(path? path) path]
      [(string? path) (string->path path)]
      [else #f]))
  (and exe
       p
       (string? expected-hex)
       (regexp-match? sha256-rx expected-hex)
       (file-exists? p)
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (define out (open-output-string))
         (define code
           (parameterize ([current-output-port out])
             (system*/exit-code exe "dgst" "-sha256" "-r" (path->string p))))
         (define m
           (regexp-match #px"^([0-9a-fA-F]{64})\\b" (get-output-string out)))
         (and (zero? code)
              m
              (string-ci=? (second m) expected-hex)))))

;; Numeric dotted comparison: "1.10.0" > "1.9.2"; missing segments count 0.
;; Glaze 0.x intentionally does not guess at prerelease/SemVer label ordering.
(define (newer-version? candidate current)
  (unless (numeric-version? candidate)
    (raise-argument-error 'newer-version? "numeric dotted version string" candidate))
  (unless (numeric-version? current)
    (raise-argument-error 'newer-version? "numeric dotted version string" current))
  (define (segments s)
    (map string->number (string-split s ".")))
  (define a (segments candidate))
  (define b (segments current))
  (define n (max (length a) (length b)))
  (let loop ([a (append a (make-list (- n (length a)) 0))]
             [b (append b (make-list (- n (length b)) 0))])
    (cond
      [(null? a) #f]
      [(> (first a) (first b)) #t]
      [(< (first a) (first b)) #f]
      [else (loop (rest a) (rest b))])))
