#lang racket/base

;; Update checking: fetch a version manifest over HTTP(S), compare with the
;; running version, report availability. Glaze deliberately stops here —
;; downloading and replacing a running app is a per-distribution decision
;; (notarized DMG, MSI upgrade, AppImage overwrite); the app decides what
;; an "update-available" event means.
;;
;; Manifest format (JSON):
;;   {"version": "1.2.0", "url": "https://.../releases/1.2.0", "notes": "...",
;;    "sha256": "<hex digest of the artifact at url>"}   ; optional but
;;   recommended for paid distribution: verify the download with
;;   (verify-file-sha256 artifact sha256) before swapping it in.
;;
;;   (check-update "https://example.com/app/manifest.json"
;;                 #:current-version "1.0.0")
;;   => (hasheq 'version "1.2.0" 'url "..." 'notes "..." 'sha256 "...") or #f

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

;; Run network work under its own custodian so timeout means the socket and
;; worker thread are actually torn down, rather than merely abandoning a
;; blocked thread.
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

(define (read-limited-body in)
  (define body (read-bytes (add1 max-manifest-bytes) in))
  (cond
    [(eof-object? body) #""]
    [(> (bytes-length body) max-manifest-bytes) #f]
    [else body]))

;; -> body bytes or #f. Only HTTP(S) is accepted. HTTPS needs the openssl
;; collection; absent TLS support, non-2xx responses, oversized manifests and
;; timeouts all degrade to #f (caller treats that as no update information).
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
            ;; Force the openssl module to load so http-sendrecv can use it.
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
  (define body (fetch-manifest manifest-url))
  (and body
       (let ()
         (define data
           (with-handlers ([exn:fail? (lambda (e) #f)])
             (bytes->jsexpr body)))
         (and (hash? data)
              (let ([v (hash-ref data 'version #f)])
                (and (string? v)
                     (newer-version? v current)
                     (hasheq 'version v
                             'url (hash-ref data 'url #f)
                             'notes (hash-ref data 'notes #f)
                             'sha256 (hash-ref data 'sha256 #f))))))))

;; True when the file at `path` has the given SHA-256 hex digest
;; (case-insensitive). #f when openssl is missing or the file is unreadable
;; — treat #f as "cannot verify", never as "verified".
(define (verify-file-sha256 path expected-hex)
  (define exe (find-executable-path "openssl" #f))
  (define p
    (cond
      [(path? path) path]
      [(string? path) (string->path path)]
      [else #f]))
  (and exe
       p
       (regexp-match? #px"^[0-9a-fA-F]{64}$" (or expected-hex ""))
       (file-exists? p)
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (define out (open-output-string))
         (define code
           (parameterize ([current-output-port out])
             (system*/exit-code exe "dgst" "-sha256" "-r" (path->string p))))
         (define m (regexp-match #px"^([0-9a-fA-F]{64})\\b" (get-output-string out)))
         (and (zero? code)
              m
              (string-ci=? (second m) expected-hex)))))

;; Numeric dotted comparison: "1.10.0" > "1.9.2"; missing segments count 0.
(define (newer-version? candidate current)
  (define (segments s)
    (for/list ([seg (in-list (string-split s "."))]
               #:when (non-empty-string? seg))
      (or (string->number seg) 0)))
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
