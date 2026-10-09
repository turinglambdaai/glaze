#lang racket/base

;; Tauri-plugin-log-style structured logging. One logger fans records out
;; to sinks (stderr, a rotating file, the SSE event bus, or custom
;; procedures), keeps a bounded in-memory history, and — through
;; make-log-routes — lets the page write records under a capability and
;; read recent history back. Frontend writes are tagged with their source
;; and capability so a page cannot forge backend log lines.

(require json
         racket/date
         racket/file
         racket/format
         racket/list
         racket/match
         racket/string
         net/url
         web-server/http/request-structs
         "api.rkt"
         "capability.rkt"
         "events.rkt")

(provide log-level?
         log-levels
         make-glaze-logger
         glaze-logger?
         glaze-logger-history
         log-record
         log-record-time
         log-record-level
         log-record-message
         log-record-source
         log-record-data
         log-record-capability
         log-trace
         log-debug
         log-info
         log-warn
         log-error
         make-stderr-log-sink
         make-file-log-sink
         log-sink
         log-sink?
         make-log-routes)

;; ---- levels ----

(define log-levels '(trace debug info warn error))

(define (log-level? v)
  (and (memq v log-levels) #t))

(define (level>= a b)
  (>= (index-of log-levels a) (index-of log-levels b)))

(define (check-level who v)
  (unless (log-level? v)
    (raise-argument-error who "(or/c 'trace 'debug 'info 'warn 'error)" v)))

;; ---- records ----

;; A record is a structured log entry: time (ISO 8601 with milliseconds),
;; level, message, source ('backend or 'frontend), and optional data and
;; capability fields.
(struct log-record (time level message source data capability) #:transparent)

(define (record->jsexpr r)
  (define base
    (hasheq 'time
            (log-record-time r)
            'level
            (symbol->string (log-record-level r))
            'message
            (log-record-message r)
            'source
            (symbol->string (log-record-source r))))
  (define with-data
    (if (log-record-data r)
        (hash-set base 'data (log-record-data r))
        base))
  (if (log-record-capability r)
      (hash-set with-data 'capability (log-record-capability r))
      with-data))

(define (now-iso)
  (define ms (current-inexact-milliseconds))
  (define iso
    (parameterize ([date-display-format 'iso-8601])
      (date->string (seconds->date (inexact->exact (floor (/ ms 1000)))) #t)))
  (format "~a.~a" iso (~r (inexact->exact (modulo (floor ms) 1000)) #:min-width 3 #:pad-string "0")))

(define max-message-chars (* 8 1024))

;; ---- sinks ----

;; A sink filters by its own minimum level, then hands the record to the
;; procedure — per-target levels mirror the Tauri plugin's attach model.
;; Sinks are directly callable (the procedure field); the logger applies
;; the level filter before invoking them.
(struct log-sink (min-level proc) #:transparent #:property prop:procedure 1)

(define (check-sink who v)
  (cond
    [(log-sink? v) v]
    [(procedure? v) (log-sink 'trace v)]
    [else (raise-argument-error who "(or/c log-sink? procedure?)" v)]))

(define (record->line r)
  (string-append (log-record-time r)
                 " "
                 (string-upcase (symbol->string (log-record-level r)))
                 " ["
                 (symbol->string (log-record-source r))
                 "] "
                 (log-record-message r)
                 (if (log-record-data r)
                     (string-append " " (jsexpr->string (log-record-data r)))
                     "")
                 "\n"))

(define (make-stderr-log-sink #:min-level [min-level 'trace])
  (check-level 'make-stderr-log-sink min-level)
  ;; The error port is read at write time so tests (and apps) can redirect
  ;; it around individual calls.
  (log-sink min-level (lambda (r) (display (record->line r) (current-error-port)))))

;; Rotating file sink: writes human-readable lines to <root>/<name>; when a
;; line would push the file past max-bytes, shift <name>.k-1 -> <name>.k
;; (dropping the oldest) and start a fresh file. Rotation, not truncation:
;; a crash mid-write never destroys the previous files.
(define (make-file-log-sink root
                            #:name [name "glaze.log"]
                            #:max-bytes [max-bytes (* 1024 1024)]
                            #:keep [keep 3]
                            #:min-level [min-level 'trace])
  (unless (path-string? root)
    (raise-argument-error 'make-file-log-sink "path-string?" root))
  (unless (string? name)
    (raise-argument-error 'make-file-log-sink "string?" name))
  (unless (exact-positive-integer? max-bytes)
    (raise-argument-error 'make-file-log-sink "exact-positive-integer?" max-bytes))
  (unless (exact-nonnegative-integer? keep)
    (raise-argument-error 'make-file-log-sink "exact-nonnegative-integer?" keep))
  (check-level 'make-file-log-sink min-level)
  (make-directory* root)
  (define sema (make-semaphore 1))
  (define (path-for k)
    (build-path root
                (if (zero? k)
                    name
                    (format "~a.~a" name k))))
  (define (rotate!)
    (cond
      [(zero? keep)
       (define current (path-for 0))
       (when (file-exists? current)
         (delete-file current))]
      [else
       (when (file-exists? (path-for keep))
         (delete-file (path-for keep)))
       (for ([k (in-range (sub1 keep) 0 -1)])
         (define from (path-for k))
         (define to (path-for (add1 k)))
         (when (file-exists? from)
           (rename-file-or-directory from to #f)))
       (define current (path-for 0))
       (when (file-exists? current)
         (rename-file-or-directory current (path-for 1) #f))]))
  (log-sink min-level
            (lambda (r)
              (call-with-semaphore sema
                                   (lambda ()
                                     (define current (path-for 0))
                                     (define line (record->line r))
                                     (define size
                                       (if (file-exists? current)
                                           (file-size current)
                                           0))
                                     (when (> (+ size (string-length line)) max-bytes)
                                       (rotate!))
                                     (display-to-file line current #:exists 'append))))))

;; ---- logger ----

(define history-default 1000)

(struct glaze-logger (min-level sinks history-limit sema [ring #:mutable]))

(define (make-glaze-logger #:min-level [min-level 'info]
                           #:sinks [sinks '()]
                           #:file-root [file-root #f]
                           #:events [event-bus #f]
                           #:history [history-limit history-default])
  (check-level 'make-glaze-logger min-level)
  (unless (and (list? sinks) (andmap (lambda (s) (or (log-sink? s) (procedure? s))) sinks))
    (raise-argument-error 'make-glaze-logger "list of sinks or procedures" sinks))
  (when (and file-root (not (path-string? file-root)))
    (raise-argument-error 'make-glaze-logger "(or/c #f path-string?)" file-root))
  (when (and event-bus (not (event-bus? event-bus)))
    (raise-argument-error 'make-glaze-logger "(or/c #f event-bus?)" event-bus))
  (unless (or (not history-limit) (exact-positive-integer? history-limit))
    (raise-argument-error 'make-glaze-logger "(or/c #f exact-positive-integer?)" history-limit))
  (define built
    (append (list (make-stderr-log-sink))
            (if file-root
                (list (make-file-log-sink file-root))
                '())
            (if event-bus
                (list (log-sink 'trace
                                (lambda (r) (bus-broadcast! event-bus 'log (record->jsexpr r)))))
                '())
            (map (lambda (s) (check-sink 'make-glaze-logger s)) sinks)))
  (glaze-logger min-level built history-limit (make-semaphore 1) '()))

(define (glaze-logger-history logger [limit 100])
  (unless (glaze-logger? logger)
    (raise-argument-error 'glaze-logger-history "glaze-logger?" logger))
  (unless (exact-positive-integer? limit)
    (raise-argument-error 'glaze-logger-history "exact-positive-integer?" limit))
  (call-with-semaphore (glaze-logger-sema logger)
                       (lambda ()
                         (define ring (glaze-logger-ring logger))
                         (list-tail ring (max 0 (- (length ring) limit))))))

;; Commit a record to the ring and fan it out to the sinks whose minimum
;; level it meets.
(define (logger-commit! logger r)
  (call-with-semaphore (glaze-logger-sema logger)
                       (lambda ()
                         (define limit (glaze-logger-history-limit logger))
                         (define ring (glaze-logger-ring logger))
                         (set-glaze-logger-ring! logger
                                                 (if (and limit (>= (length ring) limit))
                                                     (append (rest ring) (list r))
                                                     (append ring (list r))))))
  (for ([sink (in-list (glaze-logger-sinks logger))]
        #:when (level>= (log-record-level r) (log-sink-min-level sink)))
    ((log-sink-proc sink) r)))

(define (log! logger level message #:data [data #f])
  (unless (glaze-logger? logger)
    (raise-argument-error 'log! "glaze-logger?" logger))
  (check-level 'log! level)
  (unless (and (string? message) (not (string=? message "")))
    (raise-argument-error 'log! "non-empty-string?" message))
  (when data
    (unless (jsexpr? data)
      (raise-argument-error 'log! "jsexpr?" data)))
  (when (> (string-length message) max-message-chars)
    (raise-argument-error 'log!
                          (format "message longer than ~a characters" max-message-chars)
                          message))
  (when (level>= level (glaze-logger-min-level logger))
    (logger-commit! logger
                    (log-record (now-iso)
                                level
                                message
                                'backend
                                data
                                (and (current-capability-id) (current-capability-id))))))

(define (make-level-fn level)
  (lambda (logger message #:data [data #f]) (log! logger level message #:data data)))

(define log-trace (make-level-fn 'trace))
(define log-debug (make-level-fn 'debug))
(define log-info (make-level-fn 'info))
(define log-warn (make-level-fn 'warn))
(define log-error (make-level-fn 'error))

;; ---- routes ----

(define missing (gensym 'missing))

(define (bad-parameter message)
  (raise (exn:fail:glaze:bad-param message (current-continuation-marks))))

(define (body-hash req)
  (define body (request-json-body req))
  (unless (hash? body)
    (bad-parameter "body: expected a JSON object"))
  body)

(define (make-log-routes logger #:prefix [prefix "api/log"])
  (unless (glaze-logger? logger)
    (raise-argument-error 'make-log-routes "glaze-logger?" logger))
  (unless (and (string? prefix) (not (string=? prefix "")))
    (raise-argument-error 'make-log-routes "non-empty-string?" prefix))
  (define (endpoint name)
    (string-append (string-trim prefix "/") "/" name))
  (list (POST (endpoint "write")
              (lambda (req)
                (define body (body-hash req))
                (define raw-level (hash-ref body 'level missing))
                ;; JSON has no symbols: accept "warn" and 'warn alike.
                (define level
                  (cond
                    [(symbol? raw-level) raw-level]
                    [(string? raw-level) (string->symbol raw-level)]
                    [else #f]))
                (unless (and level (log-level? level))
                  (bad-parameter "level: expected trace, debug, info, warn, or error"))
                (define message (hash-ref body 'message missing))
                (cond
                  [(eq? message missing) (bad-parameter "message: missing")]
                  [(not (string? message)) (bad-parameter "message: expected a string")]
                  [(or (string=? message "") (> (string-length message) max-message-chars))
                   (bad-parameter (format "message: expected 1..~a characters" max-message-chars))])
                (define data (hash-ref body 'data #f))
                (when data
                  (unless (jsexpr? data)
                    (bad-parameter "data: expected JSON")))
                ;; Frontend records respect the logger's minimum level, exactly
                ;; like backend ones, and carry their own source and capability
                ;; so a page cannot forge backend log lines.
                (when (level>= level (glaze-logger-min-level logger))
                  (logger-commit! logger
                                  (log-record (now-iso)
                                              level
                                              message
                                              'frontend
                                              data
                                              (and (current-capability-id) (current-capability-id)))))
                (hasheq 'ok #t))
              #:permission 'log:write)
        (GET (endpoint "history")
             (lambda (req)
               (define raw
                 (for/or ([kv (in-list (url-query (request-uri req)))])
                   (and (eq? (car kv) 'limit) (cdr kv))))
               (define limit
                 (match raw
                   [#f 100]
                   [(? string? s)
                    (define n (string->number s))
                    (if (and n (exact-positive-integer? n) (<= n 1000))
                        n
                        (bad-parameter "limit: expected an integer 1..1000"))]))
               (hasheq 'records (map record->jsexpr (glaze-logger-history logger limit))))
             #:permission 'log:read)))
