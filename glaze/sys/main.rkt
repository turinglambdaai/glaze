#lang racket/base

;; glaze/sys — desktop-system integrations beyond the tray: clipboard,
;; notifications, opening/revealing paths, and single-instance locking.

(require racket/tcp)

(provide sys-supported?
         clipboard-set!
         clipboard-get
         notify!
         open-path
         reveal-path
         single-instance?)

(define (backend-module-path)
  (case (system-type 'os)
    [(macosx) 'glaze/sys/sys-macos]
    [(windows) 'glaze/sys/sys-windows]
    [(unix) 'glaze/sys/sys-linux]
    [else 'glaze/sys/sys-stub]))

(define backend-procs #f)

(define (load-backend!)
  (unless backend-procs
    (set! backend-procs (make-hash))
    (define mod (backend-module-path))
    (for ([name (in-list '(supported? clipboard-set! clipboard-get notify!
                                      open-path reveal-path))])
      (hash-set! backend-procs name (dynamic-require mod name))))
  backend-procs)

(define (ref name)
  (hash-ref (load-backend!) name))

(define (sys-supported?)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'supported?))))

;; Platform failures are best-effort values, but caller type errors remain
;; visible contracts instead of being swallowed into #f/"".
(define (clipboard-set! text)
  (unless (string? text)
    (raise-argument-error 'clipboard-set! "string?" text))
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'clipboard-set!) text)))

(define (clipboard-get)
  (with-handlers ([exn:fail? (lambda (e) "")])
    ((ref 'clipboard-get))))

(define (notify! title [body ""] #:subtitle [subtitle ""])
  (unless (string? title)
    (raise-argument-error 'notify! "string?" title))
  (unless (string? body)
    (raise-argument-error 'notify! "string?" body))
  (unless (string? subtitle)
    (raise-argument-error 'notify! "string?" subtitle))
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'notify!) title body subtitle)))

(define (path-argument->string who p)
  (cond
    [(path? p) (path->string p)]
    [(string? p) p]
    [else (raise-argument-error who "(or/c path? string?)" p)]))

(define (open-path p)
  (define s (path-argument->string 'open-path p))
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'open-path) s)))

(define (reveal-path p)
  (define s (path-argument->string 'reveal-path p))
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'reveal-path) s)))

;; ---- single instance ----

(define instance-locks (make-hash))
(define instance-locks-sema (make-semaphore 1))

(define (app-id->lock-port app-id)
  (define h
    (for/fold ([h 2166136261])
              ([b (in-bytes (string->bytes/utf-8 app-id))])
      (bitwise-and (* (bitwise-xor h b) 16777619) #xffffffff)))
  (+ 49152 (modulo h 16384)))

;; Hold a deterministic loopback listener strongly for the process lifetime.
;; This is intentionally a lightweight 0.x lock rather than an OS-specific IPC
;; protocol; collisions with an unrelated process conservatively report #f.
(define (single-instance? app-id)
  (unless (and (string? app-id) (positive? (string-length app-id)))
    (raise-argument-error 'single-instance? "non-empty-string?" app-id))
  (call-with-semaphore
   instance-locks-sema
   (lambda ()
     (cond
       [(hash-has-key? instance-locks app-id) #f]
       [else
        (define cust (make-custodian))
        (with-handlers ([exn:fail:network?
                         (lambda (e)
                           (custodian-shutdown-all cust)
                           #f)])
          (define listener
            (parameterize ([current-custodian cust])
              (tcp-listen (app-id->lock-port app-id) 1 #f "127.0.0.1")))
          (hash-set! instance-locks app-id (cons cust listener))
          #t)]))))
