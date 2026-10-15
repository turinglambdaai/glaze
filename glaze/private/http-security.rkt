#lang racket/base

;; Pure policy plus request adapters for the loopback HTTP development
;; transport. Keeping these checks together makes the trust boundary directly
;; testable and prevents route/static handlers from inventing exceptions.

(require net/url
         racket/list
         racket/string
         web-server/http/request-structs)

(provide loopback-host-value?
         content-length-too-large?
         cross-site-values?
         token-values-match?
         request-host-allowed?
         request-body-too-large?
         request-cross-site?
         request-token-ok?)

(define loopback-host-rx
  #px"^(?:(?:127[.]0[.]0[.]1|localhost)(?::[0-9]+)?|[[]::1[]](?::[0-9]+)?|::1)$")

(define (loopback-host-value? value)
  (and (string? value) (regexp-match? loopback-host-rx (string-downcase value)) #t))

(define (content-length-too-large? value limit)
  (define size (and value (string->number (string-trim value))))
  (and size (exact-positive-integer? size) (> size limit)))

(define (cross-site-values? origin fetch-site port)
  (cond
    [origin
     (with-handlers ([exn:fail? (lambda (_) #t)])
       (define uri (string->url origin))
       (not (and (equal? (url-scheme uri) "http")
                 (member (url-host uri) '("127.0.0.1" "localhost" "::1"))
                 (let ([origin-port (url-port uri)])
                   (if origin-port
                       (= origin-port port)
                       (= port 80))))))]
    [fetch-site (not (member fetch-site '("same-origin" "none")))]
    [else #f]))

(define (cookie-value cookie-string name)
  (and cookie-string
       (for/or ([part (in-list (string-split cookie-string ";"))])
         (define trimmed (string-trim part))
         (define equals-index
           (for/or ([character (in-string trimmed)]
                    [index (in-naturals)]
                    #:when (char=? character #\=))
             index))
         (and equals-index
              (string=? (substring trimmed 0 equals-index) name)
              (substring trimmed (add1 equals-index))))))

(define (token-values-match? header-value cookie-string expected)
  (or (and header-value (string=? header-value expected))
      (equal? (cookie-value cookie-string "glaze_token") expected)))

(define (header-string req name)
  (define found (headers-assq name (request-headers/raw req)))
  (and found (bytes->string/latin-1 (header-value found))))

(define (request-host-allowed? req)
  (define host (header-string req #"Host"))
  ;; HTTP/1.0 and raw programmatic clients may omit Host. They did not supply
  ;; a DNS name that could be used for rebinding, so preserve compatibility.
  (or (not host) (loopback-host-value? host)))

(define (request-body-too-large? req limit)
  (content-length-too-large? (header-string req #"Content-Length") limit))

(define (request-cross-site? req port)
  (cross-site-values? (header-string req #"Origin") (header-string req #"Sec-Fetch-Site") port))

(define (request-token-ok? req expected)
  (token-values-match? (header-string req #"X-Glaze-Token") (header-string req #"Cookie") expected))
