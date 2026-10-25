#lang racket/base

;; Framework performance baseline (G4-S2, the pattern learned from Rivet's
;; integration --benchmark mode). Measures the real native-transport stack
;; end to end — start-native-transport, GLZ1 dispatch, typed routes, stream
;; framing — instead of a detached codec microbenchmark. Emits one JSON
;; report with schema version 1.
;;
;; Honest-baseline rules (docs/benchmarks.md): every timed operation
;; validates its result, the report records platform/architecture/
;; configuration so contexts are not compared as one series, and the
;; measured values carry NO pass/fail thresholds. Shared CI runner timing
;; variance cannot fail a build; the numbers are a baseline and regression
;; investigation tool.
;;
;;   racket scripts/measure-baseline.rkt            # human-readable
;;   racket scripts/measure-baseline.rkt --json     # machine report

(require json
         racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/match
         racket/port
         racket/string
         glaze/api
         glaze/api-macros
         glaze/bridge
         glaze/events
         glaze/native-transport
         (only-in glaze/types GString))

(define schema-version 1)

(define-api-routes bench-typed
                   [(POST "api/typed-echo") (typed-echo [word GString]) (hasheq 'word word)])

(define routes
  (append bench-typed
          (list (GET "api/ping" (lambda (_req) (hasheq 'pong #t)))
                (GET "api/stream"
                     (lambda (_req)
                       (streaming-response (lambda (out)
                                             (for ([chunk (in-list '("alpha-" "beta-" "gamma-"))])
                                               (display chunk out)
                                               (flush-output out)))))))))

;; ---- measurement helpers ----

(define (us-per-op total-ms iterations)
  (exact->inexact (/ (* total-ms 1000.0) (max iterations 1))))

(define (timed-group name iterations thunk)
  ;; Warm-up runs are untimed; every timed iteration validates its result
  ;; via thunk's own check (it raises on a wrong result, so a fast but
  ;; incorrect run fails instead of producing a number).
  (define warmup (max 10 (quotient iterations 20)))
  (for ([_ (in-range warmup)])
    (thunk))
  (collect-garbage)
  (define started (current-inexact-milliseconds))
  (for ([_ (in-range iterations)])
    (thunk))
  (define total-ms (- (current-inexact-milliseconds) started))
  (hash 'iterations
        iterations
        'total_ms
        (exact->inexact total-ms)
        'us_per_operation
        (us-per-op total-ms iterations)))

;; ---- the benchmark groups ----

(define table (make-request-table))

;; Synchronous dispatch through the transport-owned bridge core — the exact
;; pipeline a GLZ1 message walks (route lookup, typed validation, capability
;; check, response envelope) minus the host delivery hop, which the
;; conformance suite covers end to end with a real window.
(define (invoke path method body)
  (define reply
    (dispatch-bridge (hasheq 'glz 1 'id "bench" 'path path 'method method 'args body)
                     routes
                     #f
                     table
                     route->js-name))
  (unless (and (hash? reply) (equal? (hash-ref reply 'ok #f) #t))
    (error 'measure-baseline "invoke ~a failed: ~s" path reply))
  (hash-ref reply 'value))

(define (transport-startup-ms samples)
  ;; A fresh transport per sample: startup is itself one of the measured
  ;; costs (route compilation, bootstrap JS, stream/event wiring), and each
  ;; sample ends with a full shutdown so nothing leaks between samples.
  (define results
    (for/list ([_ (in-range samples)])
      (collect-garbage)
      (define started (current-inexact-milliseconds))
      (define t (start-native-transport #:api routes #:public-dir (find-system-path 'temp-dir)))
      (native-transport-shutdown! t)
      (- (current-inexact-milliseconds) started)))
  (define median (let ([sorted (sort results <)]) (list-ref sorted (quotient (length sorted) 2))))
  (hash 'samples
        samples
        'median_ms
        (exact->inexact median)
        'min_ms
        (exact->inexact (argmin (lambda (v) v) results))
        'max_ms
        (exact->inexact (argmax (lambda (v) v) results))))

(define (invoke-groups)
  (hash 'ping
        (timed-group "ping"
                     1000
                     (lambda ()
                       (unless (equal? (hash-ref (invoke "api/ping" "GET" (hasheq)) 'pong) #t)
                         (error 'measure-baseline "ping returned a wrong result"))))
        'typed-echo
        (timed-group
         "typed-echo"
         1000
         (lambda ()
           (unless (equal? (hash-ref (invoke "api/typed-echo" "POST" (hasheq 'word "ok")) 'word) "ok")
             (error 'measure-baseline "typed-echo returned a wrong result"))))))

(define (stream-group)
  (define (one-stream)
    (define reply
      (dispatch-bridge (hasheq 'glz 1 'id "bench" 'path "api/stream" 'method "GET" 'args (hasheq))
                       routes
                       #f
                       table
                       route->js-name))
    ;; A streaming route dispatches and returns the raw web-server
    ;; response (the transport frames it on its own threads); only a
    ;; GLZ1 error envelope means failure.
    (when (and (hash? reply) (equal? (hash-ref reply 'ok #f) #f))
      (error 'measure-baseline "stream failed: ~s" reply))
    reply)
  ;; A streaming invoke returns after dispatch + stream registration; the
  ;; frames are delivered on the transport's own threads, whose per-chunk
  ;; latency evidence lives in the conformance suite. This group measures
  ;; the dispatch/registration cost.
  (timed-group "stream-accept" 200 one-stream))

(define (burst n offset)
  (for ([i (in-range n)])
    (invoke "api/ping" "GET" (hasheq))))

(define (resource-growth)
  ;; Long-run leak probe: two equal bursts with a GC between them. A leak
  ;; shows as continued heap growth into the second burst; a healthy stack
  ;; plateaus. Thread/handle cleanup is owned by the deterministic-teardown
  ;; conformance scenario (shutdown joins its threads, idempotent, stats
  ;; frozen), so this group records heap only.
  (burst 2000 1)
  (collect-garbage)
  (define heap-after-burst-1 (current-memory-use))
  (burst 2000 2)
  (collect-garbage)
  (define heap-after-burst-2 (current-memory-use))
  (hash 'invokes
        4000
        'heap-bytes-after-burst-1
        heap-after-burst-1
        'heap-bytes-after-burst-2
        heap-after-burst-2
        'heap-growth-b2-b1
        (- heap-after-burst-2 heap-after-burst-1)))

;; ---- main ----

(define json-mode? (make-parameter #f))
(define samples (make-parameter 7))

;; Manual arg parse (rivet's run-measure shape): command-line's clause
;; macro fights bare-symbol formals in scripts, and two flags do not need it.
(let loop ([args (vector->list (current-command-line-arguments))])
  (cond
    [(null? args) (void)]
    [(equal? (car args) "--json")
     (json-mode? #t)
     (loop (cdr args))]
    [(equal? (car args) "--samples")
     (unless (pair? (cdr args))
       (error 'measure-baseline "--samples requires a value"))
     (define n (string->number (cadr args)))
     (unless (and (real? n) (positive? n))
       (error 'measure-baseline "--samples requires a positive number"))
     (samples n)
     (loop (cddr args))]
    [else (error 'measure-baseline "unknown argument ~a; use --json or --samples N" (car args))]))

(define report
  (let ()
    (collect-garbage)
    (define startup (transport-startup-ms (samples)))
    (define groups (invoke-groups))
    (define stream (stream-group))
    (define growth (resource-growth))
    (hasheq 'schema_version
            schema-version
            'platform
            (symbol->string (system-type 'os))
            'architecture
            (symbol->string (system-type 'arch))
            'configuration
            "development"
            'racket-version
            (version)
            'transport_startup
            startup
            'invoke
            groups
            'stream
            stream
            'resources
            growth)))

(if (json-mode?)
    (write-json report)
    (let ([startup (hash-ref report 'transport_startup)]
          [growth (hash-ref report 'resources)])
      (printf "glaze framework baseline (schema ~a)\n" schema-version)
      (printf "  platform: ~a / ~a / racket ~a\n"
              (hash-ref report 'platform)
              (hash-ref report 'architecture)
              (hash-ref report 'racket-version))
      (printf "  transport startup: ~a ms median (~a samples)\n"
              (~r (hash-ref startup 'median_ms) #:precision 1)
              (hash-ref startup 'samples))
      (for ([group (in-list '(ping typed-echo))])
        (define g (hash-ref (hash-ref report 'invoke) group))
        (printf "  invoke ~a: ~a us/op (~a iterations)\n"
                group
                (~r (hash-ref g 'us_per_operation) #:precision 1)
                (hash-ref g 'iterations)))
      (define s (hash-ref report 'stream))
      (printf "  stream accept: ~a us/op (~a iterations)\n"
              (~r (hash-ref s 'us_per_operation) #:precision 1)
              (hash-ref s 'iterations))
      (printf "  resources: heap ~a -> ~a bytes after ~a invokes (GC; growth ~a)\n"
              (hash-ref growth 'heap-bytes-after-burst-1)
              (hash-ref growth 'heap-bytes-after-burst-2)
              (hash-ref growth 'invokes)
              (hash-ref growth 'heap-growth-b2-b1))))
