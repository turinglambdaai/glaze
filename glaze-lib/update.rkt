#lang racket/base

;; Update checking: fetch a version manifest over HTTP(S), compare with the
;; running version, report availability. Glaze deliberately stops here —
;; downloading and replacing a running app is a per-distribution decision
;; (notarized DMG, MSI upgrade, AppImage overwrite); the app decides what
;; an "update-available" event means.
;;
;; Manifest format (JSON):
;;   {"version": "1.2.0", "url": "https://.../releases/1.2.0", "notes": "..."}
;;
;;   (check-update "https://example.com/app/manifest.json"
;;                 #:current-version "1.0.0")
;;   => (hasheq 'version "1.2.0" 'url "..." 'notes "...") or #f

(require json
         racket/list
         racket/port
         racket/string
         net/http-client)

(provide check-update
         newer-version?)

(define manifest-timeout-secs 5)

;; -> body bytes or #f. HTTPS needs the openssl collection; absent TLS
;; support degrades to #f (caller treats as "no update info").
(define (fetch-manifest url)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define m (regexp-match #rx"^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/]+)(/.*)?$" url))
    (unless m (error 'check-update "bad manifest url"))
    (define scheme (list-ref m 1))
    (define authority (list-ref m 2))
    (define path (or (list-ref m 3) "/"))
    (define ssl? (string-ci=? scheme "https"))
    (define hostport (string-split authority ":"))
    (define host (first hostport))
    (define port
      (or (and (= (length hostport) 2) (string->number (second hostport)))
          (if ssl? 443 80)))
    (when ssl?
      ;; force the openssl module to load so http-sendrecv can use it
      (dynamic-require 'openssl 'ssl-connect #f))
    (define-values (_st _headers in)
      (http-sendrecv host path #:port port #:ssl? (if ssl? 'auto #f)))
    (begin0
      (port->bytes in)
      (close-input-port in))))

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
                             'notes (hash-ref data 'notes #f))))))))

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
