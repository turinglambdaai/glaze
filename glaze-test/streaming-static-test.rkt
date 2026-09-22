#lang racket/base

(require rackunit
         racket/file
         racket/port
         racket/string
         net/http-client
         glaze/server)

;; Serve a multi-megabyte binary asset through the real HTTP stack. The test
;; locks down status, content type, and byte-for-byte behavior so the server can
;; stream static files without changing the public response contract.
(define public-dir (make-temporary-file "glaze-static-stream-~a" 'directory))
(define payload-path (build-path public-dir "payload.wasm"))
(define payload
  (bytes-append
   (make-bytes (* 2 1024 1024) #xA5)
   (make-bytes (* 2 1024 1024) #x5A)))

(call-with-output-file payload-path
  (lambda (out) (write-bytes payload out))
  #:exists 'replace
  #:mode 'binary)

(define shutdown #f)
(dynamic-wind
  (lambda ()
    (define-values (_port stop)
      (start-server #:port 18997 #:public-dir public-dir))
    (set! shutdown stop))
  (lambda ()
    (define-values (status headers in)
      (http-sendrecv "127.0.0.1" "/payload.wasm" #:port 18997 #:ssl? #f))
    (define actual (port->bytes in))
    (close-input-port in)
    (check-true (string-contains? (bytes->string/latin-1 status) "200"))
    (check-true
     (for/or ([h (in-list headers)])
       (string-contains? (string-downcase (bytes->string/latin-1 h))
                         "content-type: application/wasm")))
    (check-equal? (bytes-length actual) (bytes-length payload))
    (check-equal? actual payload))
  (lambda ()
    (when shutdown (shutdown))
    (when (directory-exists? public-dir)
      (delete-directory/files public-dir))))
