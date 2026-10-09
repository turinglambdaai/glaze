#lang racket/base

;; Bounded HTTP client with capability-scoped frontend routes.

(require net/base64
         net/http-client
         net/url
         racket/async-channel
         racket/list
         racket/port
         racket/string
         "api.rkt"
         "capability.rkt")

(provide http-request
         make-http-routes)

(define default-max-request-bytes (* 10 1024 1024))
(define default-max-response-bytes (* 10 1024 1024))
(define default-timeout 30)
(define default-max-redirects 5)

(define forbidden-request-headers
  '("connection" "content-length"
                 "host"
                 "proxy-authorization"
                 "te"
                 "trailer"
                 "transfer-encoding"
                 "upgrade"))

(define redirect-sensitive-headers '("authorization" "cookie"))

(define header-name-rx #px"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
(define method-rx #px"^[A-Z]+$")
(define absolute-http-url-rx #px"^https?://[^[:space:]]+$")

(define (valid-http-url? value)
  (and (string? value)
       (<= (string-length value) 8192)
       (regexp-match? absolute-http-url-rx value)
       (with-handlers ([exn:fail? (lambda (error) #f)])
         (define parsed (string->url value))
         (define host (url-host parsed))
         (and (string? host) (not (string=? host ""))))))

(define (normalize-method who value)
  (define method
    (string-upcase (cond
                     [(symbol? value) (symbol->string value)]
                     [(string? value) value]
                     [(bytes? value) (bytes->string/utf-8 value)]
                     [else (raise-argument-error who "(or/c symbol? string? bytes?)" value)])))
  (unless (regexp-match? method-rx method)
    (raise-argument-error who "HTTP method" value))
  method)

(define (header-key->string who key)
  (define text
    (cond
      [(symbol? key) (symbol->string key)]
      [(string? key) key]
      [else (raise-argument-error who "header names as strings or symbols" key)]))
  (unless (regexp-match? header-name-rx text)
    (raise-argument-error who "valid HTTP header name" key))
  text)

(define (normalize-request-headers who headers)
  (unless (hash? headers)
    (raise-argument-error who "hash?" headers))
  (define seen (make-hash))
  (define total 0)
  (define result
    (for/list ([(raw-name raw-value) (in-hash headers)])
      (define name (header-key->string who raw-name))
      (unless (string? raw-value)
        (raise-argument-error who "header values as strings" raw-value))
      (when (regexp-match? #px"[\r\n]" raw-value)
        (raise-argument-error who "header value without CR or LF" raw-value))
      (define lower-name (string-downcase name))
      (when (member lower-name forbidden-request-headers)
        (raise-arguments-error who "frontend cannot set a connection-managed header" "header" name))
      (when (hash-ref seen lower-name #f)
        (raise-arguments-error who "duplicate header name ignoring case" "header" name))
      (hash-set! seen lower-name #t)
      (set! total (+ total (string-length name) (string-length raw-value)))
      (when (> total 65536)
        (raise-arguments-error who "request headers exceed 64 KiB"))
      (string-append name ": " raw-value)))
  (if (hash-ref seen "user-agent" #f)
      result
      (cons "User-Agent: Glaze-HTTP/1" result)))

(define (body->bytes who body maximum)
  (define data
    (cond
      [(not body) #f]
      [(bytes? body) body]
      [(string? body) (string->bytes/utf-8 body)]
      [else (raise-argument-error who "(or/c #f bytes? string?)" body)]))
  (when (and data (> (bytes-length data) maximum))
    (raise-arguments-error who
                           "request body exceeds configured byte limit"
                           "limit"
                           maximum
                           "actual"
                           (bytes-length data)))
  data)

(define (read-limited input maximum who)
  (define output (open-output-bytes))
  (define buffer (make-bytes 65536))
  (let loop ([total 0])
    (define count (read-bytes-avail! buffer input))
    (cond
      [(eof-object? count) (get-output-bytes output)]
      [else
       (define next (+ total count))
       (when (> next maximum)
         (raise-arguments-error who "response body exceeds configured byte limit" "limit" maximum))
       (write-bytes buffer output 0 count)
       (loop next)])))

(define (parse-status status)
  (define text (bytes->string/latin-1 status))
  (define match (regexp-match #px"(?:^|[ ])([0-9]{3})(?:[ ]|$)" text))
  (unless match
    (error 'http-request "invalid HTTP status line: ~a" text))
  (string->number (second match)))

(define (parse-response-header line)
  (define text (bytes->string/latin-1 line))
  (define position
    (for/or ([character (in-string text)]
             [index (in-naturals)]
             #:when (char=? character #\:))
      index))
  (if position
      (list (substring text 0 position) (string-trim (substring text (add1 position))))
      (list text "")))

(define (header-value headers wanted)
  (for/or ([header (in-list headers)])
    (and (string-ci=? (first header) wanted) (second header))))

(define (url-origin text)
  (define parsed (string->url text))
  (define scheme (string-downcase (url-scheme parsed)))
  (list scheme
        (string-downcase (url-host parsed))
        (or (url-port parsed) (if (string=? scheme "https") 443 80))))

(define (same-origin? left right)
  (equal? (url-origin left) (url-origin right)))

(define (strip-redirect-sensitive-headers headers)
  (filter (lambda (header)
            (define separator
              (for/or ([character (in-string header)]
                       [index (in-naturals)]
                       #:when (char=? character #\:))
                index))
            (or (not separator)
                (not (member (string-downcase (substring header 0 separator))
                             redirect-sensitive-headers))))
          headers))

(define (single-request url method headers body maximum timeout)
  (define result (make-async-channel))
  (define custodian (make-custodian))
  (parameterize ([current-custodian custodian])
    (thread (lambda ()
              (with-handlers ([exn:fail? (lambda (error)
                                           (async-channel-put result (cons 'error error)))])
                (define-values (status raw-headers input)
                  (http-sendrecv/url (string->url url) #:method method #:headers headers #:data body))
                (dynamic-wind void
                              (lambda ()
                                (async-channel-put result
                                                   (list 'ok
                                                         (parse-status status)
                                                         (map parse-response-header raw-headers)
                                                         (read-limited input maximum 'http-request))))
                              (lambda () (close-input-port input)))))))
  (define outcome (sync/timeout timeout result))
  (cond
    [(not outcome)
     (custodian-shutdown-all custodian)
     (raise-arguments-error 'http-request "request timed out" "timeout" timeout)]
    [else
     (custodian-shutdown-all custodian)
     (if (eq? (car outcome) 'error)
         (raise (cdr outcome))
         (apply values (cdr outcome)))]))

(define redirect-statuses '(301 302 303 307 308))

(define (redirect-method status method body)
  (if (or (= status 303) (and (member status '(301 302)) (string=? method "POST")))
      (values "GET" #f)
      (values method body)))

(define (http-request url
                      #:method [method "GET"]
                      #:headers [headers (hasheq)]
                      #:body [body #f]
                      #:timeout [timeout default-timeout]
                      #:max-request-bytes [max-request-bytes default-max-request-bytes]
                      #:max-response-bytes [max-response-bytes default-max-response-bytes]
                      #:max-redirects [max-redirects default-max-redirects]
                      #:authorize-url? [authorize-url? (lambda (candidate) #t)])
  (unless (valid-http-url? url)
    (raise-argument-error 'http-request "absolute HTTP(S) URL string" url))
  (unless (and (real? timeout) (<= 0.01 timeout 300))
    (raise-argument-error 'http-request "real from 0.01 through 300" timeout))
  (unless (exact-positive-integer? max-request-bytes)
    (raise-argument-error 'http-request "exact-positive-integer?" max-request-bytes))
  (unless (exact-positive-integer? max-response-bytes)
    (raise-argument-error 'http-request "exact-positive-integer?" max-response-bytes))
  (unless (and (exact-nonnegative-integer? max-redirects) (<= max-redirects 10))
    (raise-argument-error 'http-request "integer from 0 through 10" max-redirects))
  (unless (procedure? authorize-url?)
    (raise-argument-error 'http-request "procedure?" authorize-url?))
  (define normalized-method (normalize-method 'http-request method))
  (define normalized-headers (normalize-request-headers 'http-request headers))
  (define normalized-body (body->bytes 'http-request body max-request-bytes))
  (define deadline (+ (current-inexact-milliseconds) (* timeout 1000)))
  (let loop ([current-url url]
             [current-method normalized-method]
             [current-headers normalized-headers]
             [current-body normalized-body]
             [remaining max-redirects])
    (unless (authorize-url? current-url)
      (raise-arguments-error 'http-request "URL is outside the authorized scope" "url" current-url))
    (define remaining-time (/ (- deadline (current-inexact-milliseconds)) 1000.0))
    (when (<= remaining-time 0)
      (raise-arguments-error 'http-request "request timed out" "timeout" timeout))
    (define-values (status response-headers response-body)
      (single-request current-url
                      current-method
                      current-headers
                      current-body
                      max-response-bytes
                      remaining-time))
    (define location
      (and (member status redirect-statuses) (header-value response-headers "Location")))
    (cond
      [(and location (positive? remaining))
       (define next-url (url->string (combine-url/relative (string->url current-url) location)))
       (unless (valid-http-url? next-url)
         (raise-arguments-error 'http-request "redirect target is not HTTP(S)" "url" next-url))
       (define-values (next-method next-body) (redirect-method status current-method current-body))
       (define next-headers
         (if (same-origin? current-url next-url)
             current-headers
             (strip-redirect-sensitive-headers current-headers)))
       (loop next-url next-method next-headers next-body (sub1 remaining))]
      [else
       (hasheq 'status
               status
               'url
               current-url
               'redirected
               (not (string=? current-url url))
               'headers
               response-headers
               'bodyBase64
               (bytes->string/utf-8 (base64-encode response-body #""))
               'bodyText
               (bytes->string/utf-8 response-body #\uFFFD))])))

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

(define (valid-header-hash? value)
  (with-handlers ([exn:fail? (lambda (error) #f)])
    (normalize-request-headers 'make-http-routes value)
    #t))

(define (decode-body body maximum)
  (define text (hash-ref body 'body missing))
  (define base64 (hash-ref body 'bodyBase64 missing))
  (when (and (not (eq? text missing)) (not (eq? base64 missing)))
    (bad-parameter "body and bodyBase64 are mutually exclusive"))
  (cond
    [(not (eq? text missing))
     (unless (string? text)
       (bad-parameter "body: expected a string"))
     (body->bytes 'make-http-routes text maximum)]
    [(not (eq? base64 missing))
     (unless (string? base64)
       (bad-parameter "bodyBase64: expected a string"))
     (unless (regexp-match? #px"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"
                            base64)
       (bad-parameter "bodyBase64: invalid base64"))
     (define decoded
       (with-handlers ([exn:fail? (lambda (error) (bad-parameter "bodyBase64: invalid base64"))])
         (base64-decode (string->bytes/utf-8 base64))))
     (body->bytes 'make-http-routes decoded maximum)]
    [else #f]))

(define (make-http-routes #:prefix [prefix "api/http"]
                          #:max-request-bytes [max-request-bytes default-max-request-bytes]
                          #:max-response-bytes [max-response-bytes default-max-response-bytes]
                          #:timeout [timeout default-timeout]
                          #:max-redirects [max-redirects default-max-redirects])
  (unless (and (string? prefix) (not (string=? prefix "")))
    (raise-argument-error 'make-http-routes "non-empty-string?" prefix))
  (unless (exact-positive-integer? max-request-bytes)
    (raise-argument-error 'make-http-routes "exact-positive-integer?" max-request-bytes))
  (unless (exact-positive-integer? max-response-bytes)
    (raise-argument-error 'make-http-routes "exact-positive-integer?" max-response-bytes))
  (unless (and (real? timeout) (<= 0.01 timeout 300))
    (raise-argument-error 'make-http-routes "real from 0.01 through 300" timeout))
  (unless (and (exact-nonnegative-integer? max-redirects) (<= max-redirects 10))
    (raise-argument-error 'make-http-routes "integer from 0 through 10" max-redirects))
  (define endpoint (string-append (string-trim prefix "/") "/request"))
  (define (request-url req)
    (body-ref (body-hash req) 'url valid-http-url?))
  (list
   (POST endpoint
         (lambda (req)
           (define request (body-hash req))
           (define requested-timeout
             (body-option request
                          'timeout
                          (lambda (value) (and (real? value) (<= 0.01 value timeout)))
                          timeout))
           (define requested-response-limit
             (body-option request
                          'maxResponseBytes
                          (lambda (value)
                            (and (exact-positive-integer? value) (<= value max-response-bytes)))
                          max-response-bytes))
           (define requested-redirects
             (body-option request
                          'maxRedirects
                          (lambda (value)
                            (and (exact-nonnegative-integer? value) (<= value max-redirects)))
                          max-redirects))
           (http-request
            (body-ref request 'url valid-http-url?)
            #:method
            (body-option request 'method (lambda (value) (or (string? value) (symbol? value))) "GET")
            #:headers (body-option request 'headers valid-header-hash? (hasheq))
            #:body (decode-body request max-request-bytes)
            #:timeout requested-timeout
            #:max-request-bytes max-request-bytes
            #:max-response-bytes requested-response-limit
            #:max-redirects requested-redirects
            #:authorize-url? (lambda (url)
                               (or (not (current-capability-id))
                                   (current-capability-authorized? 'http:request url)))))
         #:permission 'http:request
         #:resource request-url)))
