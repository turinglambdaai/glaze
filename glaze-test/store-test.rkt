#lang racket/base

(require json
         net/http-client
         racket/file
         racket/list
         racket/port
         racket/string
         rackunit
         glaze/capability
         glaze/events
         glaze/filesystem
         glaze/server
         glaze/store)

(define root (make-temporary-file "glaze-store-~a" 'directory))
(define outside (make-temporary-file "glaze-store-outside-~a" 'directory))
(define direct-path (build-path root "direct.json"))

;; Direct API: defaults, deterministic enumeration, explicit save/reload, and
;; the semantic difference between clear and reset.
(define direct (load-store direct-path #:defaults (hasheq 'theme "dark" 'count 1) #:auto-save #f))
(check-equal? (store-get direct "theme") "dark")
(check-equal? (store-count direct) 2)
(check-equal? (store-keys direct) '("count" "theme"))
(store-set! direct "count" 2)
(store-set! direct "nested" (hasheq 'enabled #t))
(check-true (store-has-key? direct 'nested))
(check-equal? (store-get direct 'count) 2)
(check-equal? (store-values direct) (list 2 (hasheq 'enabled #t) "dark"))
(check-equal? (store-entries direct)
              (list (list "count" 2) (list "nested" (hasheq 'enabled #t)) (list "theme" "dark")))
(check-false (file-exists? direct-path))
(store-save! direct)
(check-true (file-exists? direct-path))

(fs-write-text! direct-path "{\"count\":9,\"external\":true}\n")
(store-reload! direct)
(check-equal? (store-get direct 'count) 9)
(check-true (store-get direct 'external))
(check-equal? (store-get direct 'theme) "dark")
(store-reload! direct #:ignore-defaults? #t)
(check-false (store-has-key? direct 'theme))
(check-equal? (store-count direct) 2)

(store-clear! direct)
(check-equal? (store-count direct) 0)
(store-reset! direct)
(check-equal? (hash-ref (store-snapshot direct) 'theme) "dark")
(check-equal? (hash-ref (store-snapshot direct) 'count) 1)
(check-true (store-delete! direct "theme"))
(check-false (store-delete! direct "missing"))
(store-close! direct)
(check-exn exn:fail? (lambda () (store-get direct "count")))

(define override
  (load-store direct-path #:defaults (hasheq 'theme "light") #:auto-save #f #:override-defaults? #t))
(check-false (store-has-key? override 'theme))
(check-equal? (store-get override 'count) 9)
(store-close! override)
(define fresh (load-store direct-path #:defaults (hasheq 'fresh #t) #:auto-save #f #:create-new? #t))
(check-true (store-get fresh 'fresh))
(check-false (store-has-key? fresh 'count))
(store-close! fresh)

(define unsaved-path (build-path root "unsaved.json"))
(define unsaved (load-store unsaved-path #:auto-save #f))
(store-set! unsaved "discarded" #t)
(store-close! unsaved)
(check-false (file-exists? unsaved-path))

;; Debounced auto-save writes the newest revision atomically.
(define auto-path (build-path root "auto.json"))
(define automatic (load-store auto-path #:auto-save 20))
(store-set! automatic "revision" 1)
(store-set! automatic "revision" 2)
(check-true (let loop ([attempts 100])
              (cond
                [(and (file-exists? auto-path)
                      (= (hash-ref (string->jsexpr (fs-read-text auto-path)) 'revision) 2))
                 #t]
                [(zero? attempts) #f]
                [else
                 (sleep 0.02)
                 (loop (sub1 attempts))])))
(store-close! automatic)

;; Capability-gated frontend routes are rooted, cached, auto-saved, and keep
;; read/write permissions distinct.
(define authority
  (make-capability "main"
                   (list (path-permission 'store:read #:allow (list root))
                         (path-permission 'store:write #:allow (list root))
                         'glaze:events)))
(define token "store-test-token")
(define bus (make-event-bus))
(define changes (bus-subscribe! bus))
(check-exn exn:fail:contract? (lambda () (make-store-routes)))
(define store-routes
  (make-store-routes #:root root #:defaults (hasheq 'language "en") #:auto-save 10 #:events bus))
(define-values (_port shutdown)
  (start-server #:port 18977
                #:public-dir root
                #:api-token token
                #:capability authority
                #:events bus
                #:api store-routes))

(define (call path body)
  (define-values (status headers in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port 18977
                   #:ssl? #f
                   #:method "POST"
                   #:data (string->bytes/utf-8 (jsexpr->string body))
                   #:headers (list "Content-Type: application/json"
                                   (string-append "X-Glaze-Token: " token))))
  (define response-bytes (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status)
          (and (positive? (bytes-length response-bytes)) (bytes->jsexpr response-bytes))))

(define route-path "settings.json")
(let-values ([(status body) (call "/api/store/load"
                                  (hasheq 'path route-path 'defaults (hasheq 'language "zh-CN")))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref (hash-ref body 'entries) 'language) "zh-CN"))

(let-values ([(status body) (call "/api/store/set"
                                  (hasheq 'path route-path 'key "volume" 'value 0.75))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref body 'ok)))
(define set-event (bus-wait changes 1))
(check-equal? (second set-event) 'store:change)
(check-equal? (hash-ref (third set-event) 'key) "volume")
(check-equal? (hash-ref (third set-event) 'value) 0.75)
(check-true (hash-ref (third set-event) 'exists))
(let-values ([(status body) (call "/api/store/get" (hasheq 'path route-path 'key "volume"))])
  (check-true (hash-ref body 'exists))
  (check-equal? (hash-ref body 'value) 0.75))
(let-values ([(status body) (call "/api/store/has" (hasheq 'path route-path 'key "missing"))])
  (check-false (hash-ref body 'exists)))
(let-values ([(status body) (call "/api/store/keys" (hasheq 'path route-path))])
  (check-equal? (hash-ref body 'keys) '("language" "volume")))
(let-values ([(status body) (call "/api/store/values" (hasheq 'path route-path))])
  (check-equal? (hash-ref body 'values) '("zh-CN" 0.75)))
(let-values ([(status body) (call "/api/store/entries" (hasheq 'path route-path))])
  (check-equal? (hash-ref body 'entries) (list (list "language" "zh-CN") (list "volume" 0.75))))
(let-values ([(status body) (call "/api/store/length" (hasheq 'path route-path))])
  (check-equal? (hash-ref body 'length) 2))

(let-values ([(status body) (call "/api/store/delete" (hasheq 'path route-path 'key "volume"))])
  (check-true (hash-ref body 'deleted)))
(define delete-event (bus-wait changes 1))
(check-equal? (hash-ref (third delete-event) 'key) "volume")
(check-false (hash-ref (third delete-event) 'exists))
(let-values ([(status body) (call "/api/store/clear" (hasheq 'path route-path))])
  (check-true (hash-ref body 'ok)))
(check-equal? (hash-ref (third (bus-wait changes 1)) 'key) "language")
(let-values ([(status body) (call "/api/store/length" (hasheq 'path route-path))])
  (check-equal? (hash-ref body 'length) 0))
(let-values ([(status body) (call "/api/store/reset" (hasheq 'path route-path))])
  (check-equal? (hash-ref (hash-ref body 'entries) 'language) "zh-CN"))
(check-equal? (hash-ref (third (bus-wait changes 1)) 'key) "language")
(let-values ([(status body) (call "/api/store/save" (hasheq 'path route-path))])
  (check-true (hash-ref body 'ok)))
(check-true (file-exists? (build-path root route-path)))
(fs-write-text! (build-path root route-path) "{\"fromDisk\":true}\n")
(let-values ([(status body) (call "/api/store/reload" (hasheq 'path route-path 'ignoreDefaults #t))])
  (check-true (hash-ref (hash-ref body 'entries) 'fromDisk))
  (check-false (hash-has-key? (hash-ref body 'entries) 'language)))

(let-values ([(status body) (call "/api/store/load" (hasheq 'path "../escape.json"))])
  (check-true (string-contains? status "403"))
  (check-false (file-exists? (build-path outside "escape.json"))))

(let-values ([(status body) (call "/api/store/close" (hasheq 'path route-path))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref body 'closed)))

(shutdown)
(bus-unsubscribe! bus changes)
(delete-directory/files root)
(delete-directory/files outside)
