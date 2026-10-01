#lang racket/base

;; Capability-ready child-process plugin. Commands are executed directly,
;; without an intervening shell, so arguments never undergo shell expansion.

(require racket/file
         racket/format
         racket/port
         racket/random
         racket/string
         "api.rkt"
         "capability.rkt")

(provide shell-process?
         shell-process-id
         shell-process-pid
         shell-spawn!
         shell-output
         shell-process-info
         shell-process-write!
         shell-process-close-input!
         shell-process-kill!
         shell-process-wait
         make-shell-routes)

(struct captured-output (port lock count limit truncated?) #:mutable)
(struct shell-process
        (id process
            stdout
            stdin
            stderr
            stdout-capture
            stderr-capture
            stdout-thread
            stderr-thread
            watcher
            started-ms
            owner
            finished-ms)
  #:mutable
  #:transparent)

(define (random-id)
  (apply string-append
         (for/list ([byte (in-bytes (crypto-random-bytes 16))])
           (~r byte #:base 16 #:min-width 2 #:pad-string "0"))))

(define (make-captured-output limit)
  (captured-output (open-output-bytes) (make-semaphore 1) 0 limit #f))

(define (capture-write! capture chunk)
  (call-with-semaphore
   (captured-output-lock capture)
   (lambda ()
     (define remaining (- (captured-output-limit capture) (captured-output-count capture)))
     (define keep (min remaining (bytes-length chunk)))
     (when (positive? keep)
       (write-bytes chunk (captured-output-port capture) 0 keep)
       (set-captured-output-count! capture (+ (captured-output-count capture) keep)))
     (when (< keep (bytes-length chunk))
       (set-captured-output-truncated?! capture #t)))))

(define (start-capture-thread input capture)
  (thread (lambda ()
            (let loop ()
              (define chunk (read-bytes 4096 input))
              (unless (eof-object? chunk)
                (capture-write! capture chunk)
                (loop)))
            (close-input-port input))))

(define (capture-snapshot capture)
  (call-with-semaphore (captured-output-lock capture)
                       (lambda ()
                         (values (get-output-bytes (captured-output-port capture) #f)
                                 (captured-output-truncated? capture)))))

(define (valid-arguments? arguments)
  (and (list? arguments) (andmap string? arguments)))

(define (valid-environment? environment)
  (and (hash? environment)
       (for/and ([(key value) (in-hash environment)])
         (and (or (string? key) (symbol? key)) (or (string? value) (not value))))))

(define (environment-key->bytes key)
  (string->bytes/utf-8 (if (symbol? key)
                           (symbol->string key)
                           key)))

(define (make-environment overrides)
  (define environment (environment-variables-copy (current-environment-variables)))
  (when overrides
    (for ([(key value) (in-hash overrides)])
      (environment-variables-set! environment
                                  (environment-key->bytes key)
                                  (and value (string->bytes/utf-8 value)))))
  environment)

(define (resolve-program program)
  (or (find-executable-path program)
      (and (file-exists? program) (path->complete-path program))
      (raise-arguments-error 'shell-spawn! "executable was not found" "program" program)))

(define (shell-spawn! program
                      [arguments '()]
                      #:cwd [cwd #f]
                      #:env [environment #f]
                      #:max-output [max-output (* 1024 1024)])
  (unless (path-string? program)
    (raise-argument-error 'shell-spawn! "path-string?" program))
  (unless (valid-arguments? arguments)
    (raise-argument-error 'shell-spawn! "list of strings" arguments))
  (unless (or (not cwd) (path-string? cwd))
    (raise-argument-error 'shell-spawn! "(or/c #f path-string?)" cwd))
  (unless (or (not environment) (valid-environment? environment))
    (raise-argument-error 'shell-spawn! "(or/c #f environment hash)" environment))
  (unless (exact-positive-integer? max-output)
    (raise-argument-error 'shell-spawn! "exact-positive-integer?" max-output))
  (define executable (resolve-program program))
  (define child-environment (make-environment environment))
  (define-values (process stdout stdin stderr)
    (parameterize ([current-directory (if cwd
                                          (path->complete-path cwd)
                                          (current-directory))]
                   [current-environment-variables child-environment])
      (apply subprocess #f #f #f executable arguments)))
  (define stdout-capture (make-captured-output max-output))
  (define stderr-capture (make-captured-output max-output))
  (define stdout-thread (start-capture-thread stdout stdout-capture))
  (define stderr-thread (start-capture-thread stderr stderr-capture))
  (define child
    (shell-process (random-id)
                   process
                   stdout
                   stdin
                   stderr
                   stdout-capture
                   stderr-capture
                   stdout-thread
                   stderr-thread
                   #f
                   (current-inexact-milliseconds)
                   (current-capability-id)
                   #f))
  (set-shell-process-watcher!
   child
   (thread (lambda ()
             (subprocess-wait process)
             (thread-wait stdout-thread)
             (thread-wait stderr-thread)
             (set-shell-process-finished-ms! child (current-inexact-milliseconds)))))
  child)

(define (shell-process-pid child)
  (unless (shell-process? child)
    (raise-argument-error 'shell-process-pid "shell-process?" child))
  (subprocess-pid (shell-process-process child)))

(define (shell-process-close-input! child)
  (unless (shell-process? child)
    (raise-argument-error 'shell-process-close-input! "shell-process?" child))
  (unless (port-closed? (shell-process-stdin child))
    (close-output-port (shell-process-stdin child)))
  (void))

(define (shell-process-write! child data)
  (unless (shell-process? child)
    (raise-argument-error 'shell-process-write! "shell-process?" child))
  (unless (or (string? data) (bytes? data))
    (raise-argument-error 'shell-process-write! "(or/c string? bytes?)" data))
  (when (port-closed? (shell-process-stdin child))
    (raise-arguments-error 'shell-process-write! "standard input is closed"))
  (if (bytes? data)
      (write-bytes data (shell-process-stdin child))
      (display data (shell-process-stdin child)))
  (flush-output (shell-process-stdin child))
  (void))

(define (shell-process-kill! child [force? #t])
  (unless (shell-process? child)
    (raise-argument-error 'shell-process-kill! "shell-process?" child))
  (unless (boolean? force?)
    (raise-argument-error 'shell-process-kill! "boolean?" force?))
  (when (eq? (subprocess-status (shell-process-process child)) 'running)
    (subprocess-kill (shell-process-process child) force?))
  (void))

(define (shell-process-wait child [timeout #f])
  (unless (shell-process? child)
    (raise-argument-error 'shell-process-wait "shell-process?" child))
  (unless (or (not timeout) (and (real? timeout) (not (negative? timeout))))
    (raise-argument-error 'shell-process-wait "(or/c #f nonnegative-real?)" timeout))
  (and (if timeout
           (sync/timeout timeout (shell-process-watcher child))
           (sync (shell-process-watcher child)))
       #t))

(define (bytes->display-string bytes)
  (bytes->string/utf-8 bytes #\uFFFD))

(define (shell-process-info child)
  (unless (shell-process? child)
    (raise-argument-error 'shell-process-info "shell-process?" child))
  (define status (subprocess-status (shell-process-process child)))
  (when (not (eq? status 'running))
    (thread-wait (shell-process-watcher child)))
  (define-values (stdout stdout-truncated?) (capture-snapshot (shell-process-stdout-capture child)))
  (define-values (stderr stderr-truncated?) (capture-snapshot (shell-process-stderr-capture child)))
  (hasheq 'id
          (shell-process-id child)
          'pid
          (shell-process-pid child)
          'status
          (if (eq? status 'running) "running" "exited")
          'code
          (if (eq? status 'running) #f status)
          'stdout
          (bytes->display-string stdout)
          'stderr
          (bytes->display-string stderr)
          'stdoutTruncated
          stdout-truncated?
          'stderrTruncated
          stderr-truncated?))

(define (shell-output program
                      [arguments '()]
                      #:cwd [cwd #f]
                      #:env [environment #f]
                      #:timeout [timeout 30]
                      #:max-output [max-output (* 1024 1024)])
  (unless (or (not timeout) (and (real? timeout) (positive? timeout)))
    (raise-argument-error 'shell-output "(or/c #f positive-real?)" timeout))
  (define child (shell-spawn! program arguments #:cwd cwd #:env environment #:max-output max-output))
  (shell-process-close-input! child)
  (define completed? (shell-process-wait child timeout))
  (unless completed?
    (shell-process-kill! child #t)
    (shell-process-wait child))
  (hash-set (shell-process-info child) 'timedOut (not completed?)))

(define (bad-parameter message)
  (raise (exn:fail:glaze:bad-param message (current-continuation-marks))))

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

(define (optional-timeout-ms? value)
  (or (not value) (and (real? value) (positive? value))))

(define (command-from-request req)
  (define body (body-hash req))
  (command-resource (body-ref body 'program path-string?)
                    (body-option body 'arguments valid-arguments? '())))

(define (make-shell-routes #:prefix [prefix "api/shell"]
                           #:max-output [max-output (* 1024 1024)]
                           #:max-processes [max-processes 32]
                           #:cwd-roots [cwd-roots '()]
                           #:allow-environment [allowed-environment '()]
                           #:retention-seconds [retention-seconds 300])
  (unless (and (string? prefix) (not (string=? prefix "")))
    (raise-argument-error 'make-shell-routes "non-empty-string?" prefix))
  (unless (exact-positive-integer? max-output)
    (raise-argument-error 'make-shell-routes "exact-positive-integer?" max-output))
  (unless (exact-positive-integer? max-processes)
    (raise-argument-error 'make-shell-routes "exact-positive-integer?" max-processes))
  (unless (and (list? cwd-roots) (andmap path-string? cwd-roots))
    (raise-argument-error 'make-shell-routes "list of path strings" cwd-roots))
  (unless (and (list? allowed-environment)
               (andmap (lambda (key) (or (string? key) (symbol? key))) allowed-environment))
    (raise-argument-error 'make-shell-routes "list of strings or symbols" allowed-environment))
  (unless (and (real? retention-seconds) (positive? retention-seconds))
    (raise-argument-error 'make-shell-routes "positive-real?" retention-seconds))
  (define registry (make-hash))
  (define registry-lock (make-semaphore 1))
  (define spawn-lock (make-semaphore 1))
  (define cwd-authority
    (and (pair? cwd-roots)
         (make-capability "shell-cwd" (list (path-permission 'shell:cwd #:allow cwd-roots)))))
  (define allowed-environment-keys
    (for/list ([key (in-list allowed-environment)])
      (string-downcase (if (symbol? key)
                           (symbol->string key)
                           key))))
  (define (route-cwd? value)
    (or (not value)
        (and (path-string? value)
             cwd-authority
             (capability-authorized? cwd-authority 'shell:cwd value))))
  (define (route-environment? value)
    (or (not value)
        (and (valid-environment? value)
             (for/and ([key (in-hash-keys value)])
               (member (string-downcase (if (symbol? key)
                                            (symbol->string key)
                                            key))
                       allowed-environment-keys)))))
  ;; Constructed with the route set, outside any individual web request.
  ;; Background children must outlive the request that spawned them.
  (define process-custodian (make-custodian))
  (define (endpoint name)
    (string-append (string-trim prefix "/") "/" name))
  (define (cleanup! now)
    (define expired
      (for/list ([(id child) (in-hash registry)]
                 #:when (let ([finished (shell-process-finished-ms child)])
                          (and finished (> (- now finished) (* retention-seconds 1000)))))
        id))
    (for ([id (in-list expired)])
      (hash-remove! registry id)))
  (define (register! child)
    (call-with-semaphore registry-lock
                         (lambda ()
                           (cleanup! (current-inexact-milliseconds))
                           (hash-set! registry (shell-process-id child) child)))
    child)
  (define (make-room!)
    (call-with-semaphore registry-lock
                         (lambda ()
                           (cleanup! (current-inexact-milliseconds))
                           (when (>= (hash-count registry) max-processes)
                             (define completed
                               (sort (for/list ([(id child) (in-hash registry)]
                                                #:when (shell-process-finished-ms child))
                                       (cons id (shell-process-finished-ms child)))
                                     <
                                     #:key cdr))
                             (for ([entry (in-list completed)]
                                   #:break (< (hash-count registry) max-processes))
                               (hash-remove! registry (car entry))))
                           (when (>= (hash-count registry) max-processes)
                             (bad-parameter "process limit reached")))))
  (define (owned-child id)
    (define child
      (call-with-semaphore registry-lock
                           (lambda ()
                             (cleanup! (current-inexact-milliseconds))
                             (hash-ref registry id #f))))
    (unless (and child (equal? (shell-process-owner child) (current-capability-id)))
      (bad-parameter "id: unknown process"))
    child)
  (define (spawn-from-body body)
    (define cwd (body-option body 'cwd route-cwd? #f))
    (define environment (body-option body 'env route-environment? #f))
    (call-with-semaphore
     spawn-lock
     (lambda ()
       (make-room!)
       (register! (parameterize ([current-custodian process-custodian])
                    (shell-spawn! (body-ref body 'program path-string?)
                                  (body-option body 'arguments valid-arguments? '())
                                  #:cwd cwd
                                  #:env environment
                                  #:max-output max-output))))))
  (list (POST (endpoint "output")
              (lambda (req)
                (define body (body-hash req))
                (shell-output
                 (body-ref body 'program path-string?)
                 (body-option body 'arguments valid-arguments? '())
                 #:cwd (body-option body 'cwd route-cwd? #f)
                 #:env (body-option body 'env route-environment? #f)
                 #:timeout
                 (let ([milliseconds (body-option body 'timeoutMs optional-timeout-ms? 30000)])
                   (and milliseconds (/ milliseconds 1000.0)))
                 #:max-output max-output))
              #:permission 'shell:execute
              #:resource command-from-request)
        (POST (endpoint "spawn")
              (lambda (req)
                (define child (spawn-from-body (body-hash req)))
                (hasheq 'id (shell-process-id child) 'pid (shell-process-pid child)))
              #:permission 'shell:execute
              #:resource command-from-request)
        (POST (endpoint "status")
              (lambda (req)
                (define body (body-hash req))
                (shell-process-info (owned-child (body-ref body 'id string?))))
              #:permission 'shell:manage)
        (POST (endpoint "write")
              (lambda (req)
                (define body (body-hash req))
                (shell-process-write! (owned-child (body-ref body 'id string?))
                                      (body-ref body 'data string?))
                (hasheq 'ok #t))
              #:permission 'shell:manage)
        (POST (endpoint "close-stdin")
              (lambda (req)
                (define body (body-hash req))
                (shell-process-close-input! (owned-child (body-ref body 'id string?)))
                (hasheq 'ok #t))
              #:permission 'shell:manage)
        (POST (endpoint "kill")
              (lambda (req)
                (define body (body-hash req))
                (shell-process-kill! (owned-child (body-ref body 'id string?))
                                     (body-option body 'force boolean? #t))
                (hasheq 'ok #t))
              #:permission 'shell:manage)))
