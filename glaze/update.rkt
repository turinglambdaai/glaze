#lang racket/base

;; Glaze supports both the original lightweight update check and a signed,
;; bounded update pipeline suitable for installed desktop applications.
;; Platform-specific elevation and process replacement stay in adapters;
;; the security-sensitive selection, verification, and rollback live here.

(require json
         net/base64
         net/http-client
         net/url
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         "semver.rkt"
         "signing.rkt")

(provide check-update
         newer-version?
         verify-file-sha256
         semver?
         semver-compare
         semver<?
         semver<=?
         semver=?
         semver>=?
         semver>?
         valid-update-channel?
         channel-accepts-version?
         update-manifest-schema-version
         (struct-out update-artifact)
         (struct-out update-manifest)
         (struct-out updater-config)
         (struct-out update-candidate)
         (struct-out install-plan)
         update-manifest->payload-bytes
         payload-bytes->update-manifest
         write-signed-update-manifest
         read-signed-update-manifest
         verify-signed-update-manifest
         fetch-update-manifest
         select-update
         download-update
         verify-update-artifact!
         make-install-plan
         make-replace-install-plan
         execute-install-plan!)

(define update-manifest-schema-version 1)

(struct update-artifact (platform architecture url sha256 size installer arguments signature)
  #:transparent)
(struct update-manifest
        (application-id version
                        build
                        channel
                        published-at
                        minimum-version
                        previous-version
                        rollback-allowed?
                        rollout
                        artifacts)
  #:transparent)
(struct updater-config
        (application-id current-version
                        channel
                        platform
                        architecture
                        public-key
                        expected-key-id
                        rollout-bucket
                        maximum-download-bytes)
  #:transparent)
(struct update-candidate (manifest artifact) #:transparent)
(struct install-plan (candidate downloaded-path backup-path install restart rollback) #:transparent)

;; --------------------------------------------------------------------------
;; Backward-compatible lightweight manifest check

(define updater-user-agent '("User-Agent: Glaze-Updater/1"))
(define updater-max-redirects 10)
(define redirect-statuses '(301 302 303 307 308))

(define (status-code status who)
  (define text (bytes->string/latin-1 status))
  (define match (regexp-match #px"(?:^|[ ])([0-9]{3})(?:[ ]|$)" text))
  (unless match
    (error who "invalid HTTP status line: ~a" text))
  (string->number (second match)))

(define (response-header headers wanted)
  (for/or ([line (in-list headers)])
    (define text (bytes->string/latin-1 line))
    (define separator
      (for/or ([character (in-string text)]
               [index (in-naturals)]
               #:when (char=? character #\:))
        index))
    (and separator
         (string-ci=? (substring text 0 separator) wanted)
         (string-trim (substring text (add1 separator))))))

(define (http-url? value)
  (and (string? value)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define parsed (string->url value))
         (and (member (string-downcase (or (url-scheme parsed) "")) '("http" "https"))
              (non-empty-string? (url-host parsed))))))

;; Return the response body after resolving redirects ourselves.  In
;; particular, http-sendrecv/url does not follow the GitHub release aliases
;; used by desktop updaters.  The caller owns the returned input port.
(define (open-update-input url who #:https-only? [https-only? #f])
  (let loop ([current-url url]
             [remaining updater-max-redirects])
    (unless (http-url? current-url)
      (raise-arguments-error who "URL is not absolute HTTP(S)" "url" current-url))
    (when (and https-only? (not (https-url? current-url)))
      (raise-arguments-error who "redirect target must use HTTPS" "url" current-url))
    (define-values (status headers input)
      (http-sendrecv/url (string->url current-url) #:headers updater-user-agent))
    (define code (status-code status who))
    (define location (and (member code redirect-statuses) (response-header headers "Location")))
    (cond
      [location
       (close-input-port input)
       (when (zero? remaining)
         (error who "too many redirects fetching ~a" url))
       (define next-url (url->string (combine-url/relative (string->url current-url) location)))
       (loop next-url (sub1 remaining))]
      [(<= 200 code 299) input]
      [else
       (close-input-port input)
       (error who "HTTP request failed with status ~a for ~a" code current-url)])))

(define (fetch-legacy-manifest url)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define input (open-update-input url 'check-update))
    (begin0 (port->bytes input)
      (close-input-port input))))

(define (check-update manifest-url #:current-version [current "0.0.0"])
  (define body (fetch-legacy-manifest manifest-url))
  (and body
       (let ([data (with-handlers ([exn:fail? (lambda (_) #f)])
                     (bytes->jsexpr body))])
         (and (hash? data)
              (let ([version (hash-ref data 'version #f)])
                (and (string? version)
                     (newer-version? version current)
                     (hasheq 'version
                             version
                             'url
                             (hash-ref data 'url #f)
                             'notes
                             (hash-ref data 'notes #f)
                             'sha256
                             (hash-ref data 'sha256 #f))))))))

(define (verify-file-sha256 path expected-hex)
  (and (string? expected-hex)
       (regexp-match? #px"^[0-9A-Fa-f]{64}$" (string-trim expected-hex))
       (file-exists? path)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (string-ci=? (sha256-file path) (string-trim expected-hex)))))

;; Keep accepting the historical "1.10" form while using exact SemVer 2.0
;; precedence whenever both inputs are complete semantic versions.
(define (newer-version? candidate current)
  (cond
    [(and (semver? candidate) (semver? current)) (semver>? candidate current)]
    [else
     (define (segments value)
       (for/list ([segment (in-list (string-split value "."))]
                  #:when (non-empty-string? segment))
         (or (string->number segment) 0)))
     (define left (segments candidate))
     (define right (segments current))
     (define length* (max (length left) (length right)))
     (let loop ([left (append left (make-list (- length* (length left)) 0))]
                [right (append right (make-list (- length* (length right)) 0))])
       (cond
         [(null? left) #f]
         [(> (first left) (first right)) #t]
         [(< (first left) (first right)) #f]
         [else (loop (rest left) (rest right))]))]))

;; --------------------------------------------------------------------------
;; Signed manifest format

(define (required object key predicate expected)
  (define value
    (hash-ref object
              key
              (lambda ()
                (raise-arguments-error 'payload-bytes->update-manifest
                                       "manifest field is missing"
                                       "field"
                                       key))))
  (unless (predicate value)
    (raise-arguments-error 'payload-bytes->update-manifest
                           "manifest field has invalid type or value"
                           "field"
                           key
                           "expected"
                           expected
                           "value"
                           value))
  value)

(define (artifact->jsexpr artifact)
  (hasheq 'platform
          (symbol->string (update-artifact-platform artifact))
          'architecture
          (symbol->string (update-artifact-architecture artifact))
          'url
          (update-artifact-url artifact)
          'sha256
          (string-downcase (update-artifact-sha256 artifact))
          'size
          (update-artifact-size artifact)
          'installer
          (symbol->string (update-artifact-installer artifact))
          'arguments
          (update-artifact-arguments artifact)
          'signature
          (or (update-artifact-signature artifact) 'null)))

(define (update-manifest->payload-bytes manifest)
  (unless (update-manifest? manifest)
    (raise-argument-error 'update-manifest->payload-bytes "update-manifest?" manifest))
  (define output (open-output-bytes))
  (write-json (hasheq 'schema
                      update-manifest-schema-version
                      'application_id
                      (update-manifest-application-id manifest)
                      'version
                      (update-manifest-version manifest)
                      'build
                      (update-manifest-build manifest)
                      'channel
                      (symbol->string (update-manifest-channel manifest))
                      'published_at
                      (update-manifest-published-at manifest)
                      'minimum_version
                      (update-manifest-minimum-version manifest)
                      'previous_version
                      (or (update-manifest-previous-version manifest) 'null)
                      'rollback_allowed
                      (update-manifest-rollback-allowed? manifest)
                      'rollout
                      (update-manifest-rollout manifest)
                      'artifacts
                      (map artifact->jsexpr (update-manifest-artifacts manifest)))
              output)
  (define payload (get-output-bytes output))
  ;; Refuse to sign a value that the updater itself would reject.
  (void (payload-bytes->update-manifest payload))
  payload)

(define (jsexpr->artifact value)
  (unless (hash? value)
    (raise-argument-error 'payload-bytes->update-manifest "artifact object" value))
  (define sha256
    (required value
              'sha256
              (lambda (candidate)
                (and (string? candidate) (regexp-match? #px"^[0-9A-Fa-f]{64}$" candidate)))
              "64 hexadecimal SHA-256 characters"))
  (define signature (hash-ref value 'signature 'null))
  (unless (or (eq? signature 'null) (string? signature))
    (raise-arguments-error 'payload-bytes->update-manifest
                           "artifact signature must be null or base64 text"
                           "value"
                           signature))
  (update-artifact (string->symbol (required value 'platform string? "string"))
                   (string->symbol (required value 'architecture string? "string"))
                   (required value
                             'url
                             (lambda (candidate)
                               (and (string? candidate) (regexp-match? #px"^https://" candidate)))
                             "HTTPS URL")
                   (string-downcase sha256)
                   (required value 'size exact-nonnegative-integer? "non-negative integer")
                   (string->symbol (required value 'installer string? "string"))
                   (required value
                             'arguments
                             (lambda (candidate) (and (list? candidate) (andmap string? candidate)))
                             "array of strings")
                   (and (not (eq? signature 'null)) signature)))

(define (payload-bytes->update-manifest payload)
  (define value
    (with-handlers ([exn:fail? (lambda (error)
                                 (raise-arguments-error 'payload-bytes->update-manifest
                                                        "payload is not valid JSON"
                                                        "detail"
                                                        (exn-message error)))])
      (read-json (open-input-bytes payload))))
  (unless (hash? value)
    (raise-argument-error 'payload-bytes->update-manifest "JSON object payload" value))
  (define schema (required value 'schema exact-integer? "integer"))
  (unless (= schema update-manifest-schema-version)
    (raise-arguments-error 'payload-bytes->update-manifest
                           "unsupported update manifest schema"
                           "configured"
                           schema
                           "supported"
                           update-manifest-schema-version))
  (define version (required value 'version semver? "SemVer 2.0 string"))
  (define channel (string->symbol (required value 'channel string? "string")))
  (unless (valid-update-channel? channel)
    (raise-arguments-error 'payload-bytes->update-manifest
                           "unsupported release channel"
                           "channel"
                           channel))
  (unless (channel-accepts-version? channel version)
    (raise-arguments-error 'payload-bytes->update-manifest
                           "version is incompatible with its release channel"
                           "version"
                           version
                           "channel"
                           channel))
  (define previous (hash-ref value 'previous_version 'null))
  (unless (or (eq? previous 'null) (semver? previous))
    (raise-arguments-error 'payload-bytes->update-manifest
                           "previous_version must be null or SemVer"
                           "value"
                           previous))
  (update-manifest
   (required value
             'application_id
             (lambda (candidate) (and (string? candidate) (non-empty-string? candidate)))
             "non-empty string")
   version
   (required value 'build exact-positive-integer? "positive integer")
   channel
   (required value
             'published_at
             (lambda (candidate)
               (and (string? candidate)
                    (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
                                   candidate)))
             "UTC RFC 3339 timestamp")
   (required value 'minimum_version semver? "SemVer 2.0 string")
   (and (not (eq? previous 'null)) previous)
   (required value 'rollback_allowed boolean? "boolean")
   (required value
             'rollout
             (lambda (candidate) (and (exact-integer? candidate) (<= 0 candidate 100)))
             "integer from 0 through 100")
   (map jsexpr->artifact (required value 'artifacts list? "array"))))

(define (bytes->base64-string value)
  (bytes->string/utf-8 (base64-encode value #"")))

(define (base64-string->bytes who value)
  (unless (string? value)
    (raise-argument-error who "string?" value))
  (with-handlers ([exn:fail? (lambda (_)
                               (raise-arguments-error who "invalid base64 value" "value" value))])
    (base64-decode (string->bytes/utf-8 value))))

(define (write-signed-update-manifest manifest
                                      private-key
                                      key-id
                                      #:password [password #f]
                                      [output (current-output-port)])
  (unless (and (string? key-id) (non-empty-string? key-id))
    (raise-argument-error 'write-signed-update-manifest "non-empty string?" key-id))
  (define payload (update-manifest->payload-bytes manifest))
  (define signature (sign-bytes payload #:private-key private-key #:password password))
  (write-json (hasheq 'schema
                      update-manifest-schema-version
                      'payload
                      (bytes->base64-string payload)
                      'signature
                      (hasheq 'algorithm "ed25519" 'key_id key-id 'value signature))
              output)
  (newline output))

(define (read-signed-update-manifest input)
  (define value (read-json input))
  (unless (hash? value)
    (raise-argument-error 'read-signed-update-manifest "JSON object" value))
  (define schema (required value 'schema exact-integer? "integer"))
  (unless (= schema update-manifest-schema-version)
    (raise-arguments-error 'read-signed-update-manifest
                           "unsupported signed wrapper schema"
                           "configured"
                           schema
                           "supported"
                           update-manifest-schema-version))
  (define signature (required value 'signature hash? "object"))
  (define algorithm (required signature 'algorithm string? "string"))
  (unless (string=? algorithm "ed25519")
    (raise-arguments-error 'read-signed-update-manifest
                           "unsupported manifest signature algorithm"
                           "algorithm"
                           algorithm))
  (define payload
    (base64-string->bytes 'read-signed-update-manifest
                          (required value 'payload string? "base64 string")))
  (values (payload-bytes->update-manifest payload)
          payload
          (required signature 'key_id string? "string")
          (required signature 'value string? "base64 string")))

(define (verify-signed-update-manifest input public-key #:key-id [expected-key-id #f])
  (define-values (manifest payload key-id signature) (read-signed-update-manifest input))
  (when (and expected-key-id (not (string=? expected-key-id key-id)))
    (raise-arguments-error 'verify-signed-update-manifest
                           "manifest was signed by an unexpected key"
                           "expected"
                           expected-key-id
                           "actual"
                           key-id))
  (unless (verify-bytes payload #:public-key public-key #:signature signature)
    (error 'verify-signed-update-manifest "Ed25519 manifest signature verification failed"))
  manifest)

;; --------------------------------------------------------------------------
;; Selection, bounded download, verification, and rollback orchestration

(define (copy-limited! input output limit who)
  (define buffer (make-bytes 65536))
  (let loop ([total 0])
    (define count (read-bytes-avail! buffer input))
    (cond
      [(eof-object? count) total]
      [else
       (define next (+ total count))
       (when (> next limit)
         (error who "response exceeds configured byte limit"))
       (write-bytes buffer output 0 count)
       (loop next)])))

(define (https-url? value)
  (and (http-url? value) (string-ci=? (url-scheme (string->url value)) "https")))

(define (fetch-update-manifest manifest-url
                               public-key
                               #:key-id [key-id #f]
                               #:maximum-bytes [maximum-bytes (* 1024 1024)])
  (unless (https-url? manifest-url)
    (raise-argument-error 'fetch-update-manifest "HTTPS URL string" manifest-url))
  (define input (open-update-input manifest-url 'fetch-update-manifest #:https-only? #t))
  (dynamic-wind void
                (lambda ()
                  (define output (open-output-bytes))
                  (copy-limited! input output maximum-bytes 'fetch-update-manifest)
                  (verify-signed-update-manifest (open-input-bytes (get-output-bytes output))
                                                 public-key
                                                 #:key-id key-id))
                (lambda () (close-input-port input))))

(define (select-update config manifest)
  (unless (updater-config? config)
    (raise-argument-error 'select-update "updater-config?" config))
  (unless (update-manifest? manifest)
    (raise-argument-error 'select-update "update-manifest?" manifest))
  (cond
    [(not (string=? (updater-config-application-id config) (update-manifest-application-id manifest)))
     (error 'select-update "update manifest application identity mismatch")]
    [(not (eq? (updater-config-channel config) (update-manifest-channel manifest))) #f]
    [(not (semver>? (update-manifest-version manifest) (updater-config-current-version config))) #f]
    [(semver<? (updater-config-current-version config) (update-manifest-minimum-version manifest)) #f]
    [(>= (updater-config-rollout-bucket config) (update-manifest-rollout manifest)) #f]
    [else
     (define artifact
       (for/first ([item (in-list (update-manifest-artifacts manifest))]
                   #:when (and (eq? (update-artifact-platform item) (updater-config-platform config))
                               (eq? (update-artifact-architecture item)
                                    (updater-config-architecture config))))
         item))
     (and artifact (update-candidate manifest artifact))]))

(define (verify-update-artifact! candidate path #:public-key [public-key #f])
  (unless (update-candidate? candidate)
    (raise-argument-error 'verify-update-artifact! "update-candidate?" candidate))
  (define artifact (update-candidate-artifact candidate))
  (unless (= (file-size path) (update-artifact-size artifact))
    (raise-arguments-error 'verify-update-artifact!
                           "download size does not match signed manifest"
                           "expected"
                           (update-artifact-size artifact)
                           "actual"
                           (file-size path)))
  (define actual (string-downcase (sha256-file path)))
  (unless (string=? actual (update-artifact-sha256 artifact))
    (raise-arguments-error 'verify-update-artifact!
                           "download SHA-256 does not match signed manifest"
                           "expected"
                           (update-artifact-sha256 artifact)
                           "actual"
                           actual))
  (when (update-artifact-signature artifact)
    (unless public-key
      (error 'verify-update-artifact! "artifact signature is present but no public key was supplied"))
    (unless (verify-signature path
                              #:public-key public-key
                              #:signature (update-artifact-signature artifact)
                              #:expected-sha256 (update-artifact-sha256 artifact))
      (error 'verify-update-artifact! "Ed25519 artifact signature verification failed")))
  path)

(define (download-update config candidate destination)
  (define artifact (update-candidate-artifact candidate))
  (define maximum (updater-config-maximum-download-bytes config))
  (unless (https-url? (update-artifact-url artifact))
    (error 'download-update "signed artifact URL must use HTTPS"))
  (when (> (update-artifact-size artifact) maximum)
    (error 'download-update "signed artifact size exceeds configured download limit"))
  (make-parent-directory* destination)
  (define partial (path-add-extension destination #".partial"))
  (when (file-exists? partial)
    (delete-file partial))
  (with-handlers ([exn:fail? (lambda (error)
                               (when (file-exists? partial)
                                 (delete-file partial))
                               (raise error))])
    (define input
      (open-update-input (update-artifact-url artifact) 'download-update #:https-only? #t))
    (dynamic-wind void
                  (lambda ()
                    (call-with-output-file partial
                                           #:exists 'truncate/replace
                                           #:mode 'binary
                                           (lambda (output)
                                             (copy-limited! input output maximum 'download-update))))
                  (lambda () (close-input-port input)))
    (verify-update-artifact! candidate partial #:public-key (updater-config-public-key config))
    (rename-file-or-directory partial destination #t)
    destination))

(define (make-install-plan candidate
                           downloaded-path
                           #:backup-path [backup-path #f]
                           #:install install
                           #:restart [restart void]
                           #:rollback [rollback void])
  (unless (procedure? install)
    (raise-argument-error 'make-install-plan "procedure?" install))
  (unless (procedure? restart)
    (raise-argument-error 'make-install-plan "procedure?" restart))
  (unless (procedure? rollback)
    (raise-argument-error 'make-install-plan "procedure?" rollback))
  (install-plan candidate downloaded-path backup-path install restart rollback))

;; Atomic replacement strategy for portable artifacts such as AppImage or a
;; self-contained application archive. Native installers (MSI/EXE/PKG/DMG)
;; use make-install-plan with an adapter that owns elevation and handoff.
(define (make-replace-install-plan candidate
                                   downloaded-path
                                   target-path
                                   #:backup-path
                                   [backup-path (path-add-extension target-path #".rollback")]
                                   #:restart [restart void])
  (define staging (path-add-extension target-path #".installing"))
  (define (install source)
    (make-parent-directory* target-path)
    (when (file-exists? staging)
      (delete-file staging))
    (copy-file source staging #t)
    (when (file-exists? target-path)
      (copy-file target-path backup-path #t))
    (rename-file-or-directory staging target-path #t))
  (define (rollback)
    (when (file-exists? backup-path)
      (copy-file backup-path target-path #t)))
  (make-install-plan candidate
                     downloaded-path
                     #:backup-path backup-path
                     #:install install
                     #:restart restart
                     #:rollback rollback))

(define (execute-install-plan! plan)
  (unless (install-plan? plan)
    (raise-argument-error 'execute-install-plan! "install-plan?" plan))
  (with-handlers ([exn:fail? (lambda (error)
                               (when (update-manifest-rollback-allowed?
                                      (update-candidate-manifest (install-plan-candidate plan)))
                                 ((install-plan-rollback plan)))
                               (raise error))])
    ((install-plan-install plan) (install-plan-downloaded-path plan))
    ((install-plan-restart plan))))
