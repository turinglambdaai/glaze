#lang racket/base

;; JSON key-value stores with atomic persistence and capability-gated routes.

(require json
         racket/async-channel
         racket/file
         racket/list
         racket/path
         racket/string
         "api.rkt"
         "capability.rkt"
         "events.rkt"
         "filesystem.rkt")

(provide store?
         store-path
         load-store
         store-get
         store-set!
         store-has-key?
         store-delete!
         store-clear!
         store-reset!
         store-keys
         store-values
         store-entries
         store-count
         store-snapshot
         store-save!
         store-reload!
         store-close!
         make-store-routes)

(struct store (path defaults data lock auto-save-ms save-channel save-thread dirty? closed?)
  #:mutable
  #:transparent)

(define (bad-parameter message)
  (raise (exn:fail:glaze:bad-param message (current-continuation-marks))))

(define (normalize-key who key)
  (cond
    [(symbol? key) key]
    [(string? key) (string->symbol key)]
    [else (raise-argument-error who "(or/c string? symbol?)" key)]))

(define (normalize-object who value)
  (unless (hash? value)
    (raise-argument-error who "JSON object hash" value))
  (define normalized (make-hasheq))
  (for ([(key item) (in-hash value)])
    (unless (or (symbol? key) (string? key))
      (raise-argument-error who "JSON object with string or symbol keys" value))
    (unless (jsexpr? item)
      (raise-argument-error who "JSON-compatible values" item))
    (hash-set! normalized (normalize-key who key) item))
  normalized)

(define (copy-jsexpr value)
  (string->jsexpr (jsexpr->string value)))

(define (copy-object who value)
  (normalize-object who (copy-jsexpr (normalize-object who value))))

(define (merge-objects . objects)
  (define result (make-hasheq))
  (for ([object (in-list objects)])
    (for ([(key value) (in-hash object)])
      (hash-set! result key value)))
  result)

(define (read-store-file path)
  (define value (string->jsexpr (fs-read-text path)))
  (normalize-object 'load-store value))

(define (normalize-auto-save value)
  (cond
    [(eq? value #f) #f]
    [(eq? value #t) 100]
    [(and (real? value) (<= 0 value 86400000)) value]
    [else (raise-argument-error 'load-store "(or/c boolean? nonnegative-real?)" value)]))

(define (ensure-open who storage)
  (unless (store? storage)
    (raise-argument-error who "store?" storage))
  (when (store-closed? storage)
    (raise-arguments-error who "store is closed" "path" (store-path storage))))

(define (write-unlocked! storage [force? #f])
  (when (or force? (store-dirty? storage))
    (fs-write-text! (store-path storage) (string-append (jsexpr->string (store-data storage)) "\n"))
    (set-store-dirty?! storage #f)))

(define (auto-save-unlocked! storage)
  (when (store-save-channel storage)
    (async-channel-put (store-save-channel storage) 'save)))

(define (start-save-worker! storage)
  (define delay-seconds (/ (store-auto-save-ms storage) 1000.0))
  (define channel (make-async-channel))
  (set-store-save-channel! storage channel)
  (define worker
    (thread
     (lambda ()
       (let loop ()
         (define message (async-channel-get channel))
         (unless (eq? message 'close)
           (let debounce ()
             (define next (sync/timeout delay-seconds channel))
             (cond
               [(eq? next 'close) (void)]
               [next (debounce)]
               [else
                (with-handlers ([exn:fail? (lambda (error)
                                             (eprintf "[glaze-store] auto-save failed for ~a: ~a\n"
                                                      (store-path storage)
                                                      (exn-message error)))])
                  (call-with-semaphore (store-lock storage)
                                       (lambda ()
                                         (unless (store-closed? storage)
                                           (write-unlocked! storage)))))
                (loop)])))))))
  (set-store-save-thread! storage worker))

(define (load-store path
                    #:defaults [defaults (hasheq)]
                    #:auto-save [auto-save 100]
                    #:create-new? [create-new? #f]
                    #:override-defaults? [override-defaults? #f])
  (unless (path-string? path)
    (raise-argument-error 'load-store "path-string?" path))
  (unless (boolean? create-new?)
    (raise-argument-error 'load-store "boolean?" create-new?))
  (unless (boolean? override-defaults?)
    (raise-argument-error 'load-store "boolean?" override-defaults?))
  (define normalized-defaults (copy-object 'load-store defaults))
  (define complete-path (path->complete-path path))
  (define exists? (file-exists? complete-path))
  (define disk-data (and exists? (not create-new?) (read-store-file complete-path)))
  (define data
    (cond
      [create-new? (copy-object 'load-store normalized-defaults)]
      [(and disk-data override-defaults?) disk-data]
      [disk-data (merge-objects normalized-defaults disk-data)]
      [else (copy-object 'load-store normalized-defaults)]))
  (define storage
    (store complete-path
           normalized-defaults
           data
           (make-semaphore 1)
           (normalize-auto-save auto-save)
           #f
           #f
           (or create-new? (not exists?))
           #f))
  (when (store-auto-save-ms storage)
    (start-save-worker! storage))
  storage)

(define (store-get storage key [default #f])
  (ensure-open 'store-get storage)
  (call-with-semaphore (store-lock storage)
                       (lambda ()
                         (define value
                           (hash-ref (store-data storage) (normalize-key 'store-get key) default))
                         (if (jsexpr? value)
                             (copy-jsexpr value)
                             value))))

(define (store-set! storage key value)
  (ensure-open 'store-set! storage)
  (unless (jsexpr? value)
    (raise-argument-error 'store-set! "jsexpr?" value))
  (call-with-semaphore
   (store-lock storage)
   (lambda ()
     (hash-set! (store-data storage) (normalize-key 'store-set! key) (copy-jsexpr value))
     (set-store-dirty?! storage #t)
     (auto-save-unlocked! storage)))
  (void))

(define (store-has-key? storage key)
  (ensure-open 'store-has-key? storage)
  (call-with-semaphore (store-lock storage)
                       (lambda ()
                         (hash-has-key? (store-data storage) (normalize-key 'store-has-key? key)))))

(define (store-delete! storage key)
  (ensure-open 'store-delete! storage)
  (call-with-semaphore (store-lock storage)
                       (lambda ()
                         (define normalized (normalize-key 'store-delete! key))
                         (define existed? (hash-has-key? (store-data storage) normalized))
                         (when existed?
                           (hash-remove! (store-data storage) normalized)
                           (set-store-dirty?! storage #t)
                           (auto-save-unlocked! storage))
                         existed?)))

(define (store-clear! storage)
  (ensure-open 'store-clear! storage)
  (call-with-semaphore (store-lock storage)
                       (lambda ()
                         (hash-clear! (store-data storage))
                         (set-store-dirty?! storage #t)
                         (auto-save-unlocked! storage)))
  (void))

(define (store-reset! storage)
  (ensure-open 'store-reset! storage)
  (call-with-semaphore (store-lock storage)
                       (lambda ()
                         (set-store-data! storage
                                          (copy-object 'store-reset! (store-defaults storage)))
                         (set-store-dirty?! storage #t)
                         (auto-save-unlocked! storage)))
  (void))

(define (sorted-keys storage)
  (sort (hash-keys (store-data storage)) string<? #:key symbol->string))

(define (store-keys storage)
  (ensure-open 'store-keys storage)
  (call-with-semaphore (store-lock storage) (lambda () (map symbol->string (sorted-keys storage)))))

(define (store-values storage)
  (ensure-open 'store-values storage)
  (call-with-semaphore (store-lock storage)
                       (lambda ()
                         (for/list ([key (in-list (sorted-keys storage))])
                           (copy-jsexpr (hash-ref (store-data storage) key))))))

(define (store-entries storage)
  (ensure-open 'store-entries storage)
  (call-with-semaphore (store-lock storage)
                       (lambda ()
                         (for/list ([key (in-list (sorted-keys storage))])
                           (list (symbol->string key)
                                 (copy-jsexpr (hash-ref (store-data storage) key)))))))

(define (store-count storage)
  (ensure-open 'store-count storage)
  (call-with-semaphore (store-lock storage) (lambda () (hash-count (store-data storage)))))

(define (store-snapshot storage)
  (ensure-open 'store-snapshot storage)
  (call-with-semaphore (store-lock storage)
                       (lambda () (copy-object 'store-snapshot (store-data storage)))))

(define (store-save! storage)
  (ensure-open 'store-save! storage)
  (call-with-semaphore (store-lock storage) (lambda () (write-unlocked! storage #t)))
  (void))

(define (store-reload! storage #:ignore-defaults? [ignore-defaults? #f])
  (ensure-open 'store-reload! storage)
  (unless (boolean? ignore-defaults?)
    (raise-argument-error 'store-reload! "boolean?" ignore-defaults?))
  (call-with-semaphore (store-lock storage)
                       (lambda ()
                         (define disk-data
                           (if (file-exists? (store-path storage))
                               (read-store-file (store-path storage))
                               (make-hasheq)))
                         (set-store-data! storage
                                          (if ignore-defaults?
                                              disk-data
                                              (merge-objects (store-data storage) disk-data)))
                         (set-store-dirty?! storage #f)))
  (void))

(define (store-close! storage)
  (ensure-open 'store-close! storage)
  (call-with-semaphore (store-lock storage)
                       (lambda ()
                         (when (store-auto-save-ms storage)
                           (write-unlocked! storage))
                         (set-store-closed?! storage #t)))
  (when (store-save-channel storage)
    (async-channel-put (store-save-channel storage) 'close)
    (thread-wait (store-save-thread storage)))
  (void))

(define missing (gensym 'missing))

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

(define (valid-auto-save? value)
  (or (boolean? value) (and (real? value) (<= 0 value 86400000))))

(define (valid-defaults? value)
  (with-handlers ([exn:fail? (lambda (error) #f)])
    (copy-object 'make-store-routes value)
    #t))

(define (make-store-routes #:root root
                           #:prefix [prefix "api/store"]
                           #:defaults [route-defaults (hasheq)]
                           #:auto-save [route-auto-save 100]
                           #:events [event-bus #f])
  (unless (and (string? prefix) (not (string=? prefix "")))
    (raise-argument-error 'make-store-routes "non-empty-string?" prefix))
  (unless (path-string? root)
    (raise-argument-error 'make-store-routes "path-string?" root))
  (unless (valid-defaults? route-defaults)
    (raise-argument-error 'make-store-routes "JSON object hash" route-defaults))
  (unless (valid-auto-save? route-auto-save)
    (raise-argument-error 'make-store-routes "(or/c boolean? nonnegative-real?)" route-auto-save))
  (unless (or (not event-bus) (event-bus? event-bus))
    (raise-argument-error 'make-store-routes "(or/c #f event-bus?)" event-bus))
  (define complete-root (path->complete-path root))
  (define root-authority
    (make-capability "store-root" (list (path-permission 'store:path #:allow (list complete-root)))))
  (define registry (make-hash))
  (define registry-lock (make-semaphore 1))
  (define worker-custodian (make-custodian))
  (define (endpoint name)
    (string-append (string-trim prefix "/") "/" name))
  (define (resolve-path body)
    (define requested (body-ref body 'path path-string?))
    (define resolved
      (begin
        (when (complete-path? requested)
          (bad-parameter "path: expected a path relative to the configured store root"))
        (path->complete-path requested complete-root)))
    (when (not (capability-authorized? root-authority 'store:path resolved))
      (bad-parameter "path: outside the configured store root"))
    resolved)
  (define (path-resource req)
    (resolve-path (body-hash req)))
  (define (cache-key path)
    (cons (current-capability-id) (path->string (simplify-path path #f))))
  (define (cached-store body [load-options? #f])
    (define path (resolve-path body))
    (define key (cache-key path))
    (call-with-semaphore
     registry-lock
     (lambda ()
       (hash-ref! registry
                  key
                  (lambda ()
                    (parameterize ([current-custodian worker-custodian])
                      (load-store
                       path
                       #:defaults (if load-options?
                                      (body-option body 'defaults valid-defaults? route-defaults)
                                      route-defaults)
                       #:auto-save (if load-options?
                                       (body-option body 'autoSave valid-auto-save? route-auto-save)
                                       route-auto-save)
                       #:create-new? (and load-options? (body-option body 'createNew boolean? #f))
                       #:override-defaults?
                       (and load-options? (body-option body 'overrideDefaults boolean? #f)))))))))
  (define (summary storage)
    (hasheq 'path
            (path->string (store-path storage))
            'length
            (store-count storage)
            'entries
            (store-snapshot storage)))
  (define (broadcast-change! path key value exists?)
    (when event-bus
      (bus-broadcast! event-bus
                      'store:change
                      (hasheq 'path (path->string path) 'key key 'value value 'exists exists?))))
  (define (broadcast-difference! path before after)
    (define keys
      (sort (remove-duplicates (append (hash-keys before) (hash-keys after)))
            string<?
            #:key symbol->string))
    (for ([key (in-list keys)])
      (define before-value (hash-ref before key missing))
      (define after-value (hash-ref after key missing))
      (unless (equal? before-value after-value)
        (broadcast-change! path
                           (symbol->string key)
                           (if (eq? after-value missing) 'null after-value)
                           (not (eq? after-value missing))))))
  (list
   (POST (endpoint "load")
         (lambda (req) (summary (cached-store (body-hash req) #t)))
         #:permission 'store:read
         #:resource path-resource)
   (POST (endpoint "get")
         (lambda (req)
           (define body (body-hash req))
           (define storage (cached-store body))
           (define key (body-ref body 'key string?))
           (hasheq 'exists (store-has-key? storage key) 'value (store-get storage key 'null)))
         #:permission 'store:read
         #:resource path-resource)
   (POST (endpoint "has")
         (lambda (req)
           (define body (body-hash req))
           (hasheq 'exists (store-has-key? (cached-store body) (body-ref body 'key string?))))
         #:permission 'store:read
         #:resource path-resource)
   (POST (endpoint "set")
         (lambda (req)
           (define body (body-hash req))
           (define storage (cached-store body))
           (define key (body-ref body 'key string?))
           (define value (body-ref body 'value jsexpr?))
           (store-set! storage key value)
           (broadcast-change! (store-path storage) key value #t)
           (hasheq 'ok #t))
         #:permission 'store:write
         #:resource path-resource)
   (POST (endpoint "delete")
         (lambda (req)
           (define body (body-hash req))
           (define storage (cached-store body))
           (define key (body-ref body 'key string?))
           (define deleted? (store-delete! storage key))
           (when deleted?
             (broadcast-change! (store-path storage) key 'null #f))
           (hasheq 'deleted deleted?))
         #:permission 'store:write
         #:resource path-resource)
   (POST (endpoint "clear")
         (lambda (req)
           (define storage (cached-store (body-hash req)))
           (define before (store-snapshot storage))
           (store-clear! storage)
           (broadcast-difference! (store-path storage) before (hasheq))
           (hasheq 'ok #t))
         #:permission 'store:write
         #:resource path-resource)
   (POST (endpoint "reset")
         (lambda (req)
           (define storage (cached-store (body-hash req)))
           (define before (store-snapshot storage))
           (store-reset! storage)
           (broadcast-difference! (store-path storage) before (store-snapshot storage))
           (summary storage))
         #:permission 'store:write
         #:resource path-resource)
   (POST (endpoint "keys")
         (lambda (req) (hasheq 'keys (store-keys (cached-store (body-hash req)))))
         #:permission 'store:read
         #:resource path-resource)
   (POST (endpoint "values")
         (lambda (req) (hasheq 'values (store-values (cached-store (body-hash req)))))
         #:permission 'store:read
         #:resource path-resource)
   (POST (endpoint "entries")
         (lambda (req) (hasheq 'entries (store-entries (cached-store (body-hash req)))))
         #:permission 'store:read
         #:resource path-resource)
   (POST (endpoint "length")
         (lambda (req) (hasheq 'length (store-count (cached-store (body-hash req)))))
         #:permission 'store:read
         #:resource path-resource)
   (POST (endpoint "save")
         (lambda (req)
           (store-save! (cached-store (body-hash req)))
           (hasheq 'ok #t))
         #:permission 'store:write
         #:resource path-resource)
   (POST (endpoint "reload")
         (lambda (req)
           (define body (body-hash req))
           (define storage (cached-store body))
           (store-reload! storage #:ignore-defaults? (body-option body 'ignoreDefaults boolean? #f))
           (summary storage))
         #:permission 'store:read
         #:resource path-resource)
   (POST (endpoint "close")
         (lambda (req)
           (define body (body-hash req))
           (define path (resolve-path body))
           (define key (cache-key path))
           (define storage (call-with-semaphore registry-lock (lambda () (hash-ref registry key #f))))
           (when storage
             (store-close! storage))
           (when storage
             (call-with-semaphore registry-lock (lambda () (hash-remove! registry key))))
           (hasheq 'closed (and storage #t)))
         #:permission 'store:write
         #:resource path-resource)))
