#lang racket/base

(require json
         net/base64
         rackunit
         racket/file
         racket/port
         glaze/signing
         glaze/update)

(check-true (semver<? "1.2.3-alpha.1" "1.2.3"))
(check-true (semver=? "1.2.3+first" "1.2.3+second"))
(check-false (semver? "01.2.3"))
(check-false (semver? "1.2.3-beta.01"))
(check-true (channel-accepts-version? 'stable "1.0.0"))
(check-false (channel-accepts-version? 'stable "1.0.0-beta.1"))
(check-true (channel-accepts-version? 'beta "1.0.0-beta.1"))

(define work (make-temporary-file "glaze-update-~a" 'directory))
(define artifact-file (build-path work "app.bin"))
(define target-file (build-path work "installed.bin"))
(define private-key (build-path work "private.pem"))
(define public-key (build-path work "public.pem"))

(dynamic-wind
 void
 (lambda ()
   (call-with-output-file artifact-file
                          #:exists 'truncate/replace
                          #:mode 'binary
                          (lambda (output) (write-bytes #"test" output)))
   (define artifact
     (update-artifact 'windows
                      'x64
                      "https://updates.example/app.msi"
                      (sha256-file artifact-file)
                      4
                      'msi
                      '("/quiet")
                      #f))
   (define manifest
     (update-manifest "dev.glaze.test"
                      "1.2.0"
                      12
                      'stable
                      "2026-10-01T00:00:00Z"
                      "1.0.0"
                      "1.1.0"
                      #t
                      100
                      (list artifact)))

   (define roundtrip (payload-bytes->update-manifest (update-manifest->payload-bytes manifest)))
   (check-equal? roundtrip manifest)

   (define config
     (updater-config "dev.glaze.test"
                     "1.1.0"
                     'stable
                     'windows
                     'x64
                     public-key
                     "release-2026"
                     0
                     (* 1024 1024)))
   (define candidate (select-update config manifest))
   (check-true (update-candidate? candidate))
   (check-false (select-update (struct-copy updater-config config [current-version "1.2.0"])
                               manifest))
   (check-false (select-update (struct-copy updater-config config [rollout-bucket 75])
                               (struct-copy update-manifest manifest [rollout 50])))
   (check-exn #rx"identity mismatch"
              (lambda ()
                (select-update (struct-copy updater-config config [application-id "other.app"])
                               manifest)))

   (check-equal? (verify-update-artifact! candidate artifact-file) artifact-file)
   (call-with-output-file artifact-file
                          #:exists 'append
                          #:mode 'binary
                          (lambda (output) (write-byte 0 output)))
   (check-exn #rx"size does not match" (lambda () (verify-update-artifact! candidate artifact-file)))
   (call-with-output-file artifact-file
                          #:exists 'truncate/replace
                          #:mode 'binary
                          (lambda (output) (write-bytes #"test" output)))

   ;; The exact payload bytes are signed, and key-id pinning rejects a valid
   ;; signature made for an unexpected release key.
   (signing-keygen #:private-key private-key #:public-key public-key)
   (define signed-output (open-output-bytes))
   (write-signed-update-manifest manifest private-key "release-2026" signed-output)
   (define signed-bytes (get-output-bytes signed-output))
   (define verified
     (verify-signed-update-manifest (open-input-bytes signed-bytes)
                                    public-key
                                    #:key-id "release-2026"))
   (check-equal? (update-manifest-version verified) "1.2.0")
   (check-exn #rx"unexpected key"
              (lambda ()
                (verify-signed-update-manifest (open-input-bytes signed-bytes)
                                               public-key
                                               #:key-id "wrong-key")))

   ;; A modified payload remains valid JSON but cannot retain the signature.
   (define wrapper (read-json (open-input-bytes signed-bytes)))
   (define payload (base64-decode (string->bytes/utf-8 (hash-ref wrapper 'payload))))
   (define tampered-wrapper
     (hash-set wrapper
               'payload
               (bytes->string/utf-8 (base64-encode (bytes-append payload #" ") #""))))
   (define tampered-output (open-output-bytes))
   (write-json tampered-wrapper tampered-output)
   (check-exn #rx"signature verification failed"
              (lambda ()
                (verify-signed-update-manifest (open-input-bytes (get-output-bytes tampered-output))
                                               public-key)))

   ;; Portable replacement keeps a rollback copy and installs atomically.
   (call-with-output-file target-file
                          #:exists 'truncate/replace
                          #:mode 'binary
                          (lambda (output) (write-bytes #"old" output)))
   (execute-install-plan! (make-replace-install-plan candidate artifact-file target-file))
   (check-equal? (file->bytes target-file) #"test")
   (check-equal? (file->bytes (path-add-extension target-file #".rollback")) #"old")

   (define rolled-back? #f)
   (define failing-plan
     (make-install-plan candidate
                        artifact-file
                        #:install (lambda (_) (error 'installer "failed"))
                        #:rollback (lambda () (set! rolled-back? #t))))
   (check-exn #rx"failed" (lambda () (execute-install-plan! failing-plan)))
   (check-true rolled-back?))
 (lambda ()
   (when (directory-exists? work)
     (delete-directory/files work))))
