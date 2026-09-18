#lang racket/base

;; Public tray API. Platform-specific native code remains behind this module;
;; application-facing values are validated before they reach FFI.

(require "tray-protocol.rkt")

(provide make-tray
         tray?
         tray-backend
         tray-handle
         tray-set-tooltip!
         tray-set-icon!
         tray-set-menu!
         tray-close
         tray-supported?
         (all-from-out "tray-protocol.rkt"))

(struct tray (backend handle) #:transparent)

(define (backend-module-path)
  (case (system-type 'os)
    [(windows) 'glaze/tray/tray-windows]
    [(macosx) 'glaze/tray/tray-macos]
    [(unix) 'glaze/tray/tray-linux]
    [else 'glaze/tray/tray-stub]))

(define backend-procs #f)

(define (load-backend!)
  (unless backend-procs
    (set! backend-procs (make-hash))
    (define mod (backend-module-path))
    (for ([name (in-list '(make-tray set-tooltip! set-icon! set-menu! close supported?))])
      (hash-set! backend-procs name (dynamic-require mod name))))
  backend-procs)

(define stub-procs #f)

(define (load-stub-procs)
  (unless stub-procs
    (set! stub-procs (make-hash))
    (for ([name (in-list '(make-tray set-tooltip! set-icon! set-menu! close supported?))])
      (hash-set! stub-procs
                 name
                 (dynamic-require 'glaze/tray/tray-stub
                                  (string->symbol (format "stub:~a" name))))))
  stub-procs)

(define (ref name tbl)
  (hash-ref tbl name))

(define (tray-supported?)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'supported? (load-backend!)))))

(define (check-tray who t)
  (unless (tray? t)
    (raise-argument-error who "tray?" t)))

(define (check-icon who icon-path)
  (unless (or (not icon-path) (path? icon-path) (string? icon-path))
    (raise-argument-error who "(or/c #f path? string?)" icon-path)))

(define (check-items who items)
  (unless (and (list? items) (andmap menu-item? items))
    (raise-argument-error who "(listof menu-item?)" items)))

(define (table-for-tray t)
  (check-tray 'tray-operation t)
  (if (eq? (tray-backend t) 'stub)
      (load-stub-procs)
      (load-backend!)))

(define (make-tray #:icon icon-path
                   #:tooltip tooltip
                   #:menu items
                   #:on-event [on-event (lambda (e) (void))])
  (check-icon 'make-tray icon-path)
  (unless (string? tooltip)
    (raise-argument-error 'make-tray "string?" tooltip))
  (check-items 'make-tray items)
  (unless (and (procedure? on-event) (procedure-arity-includes? on-event 1))
    (raise-argument-error 'make-tray "procedure accepting one argument" on-event))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (fprintf (current-error-port)
                              "[glaze] tray backend unavailable (~a); using no-op stub.\n"
                              (exn-message e))
                     (define tbl (load-stub-procs))
                     (tray 'stub
                           ((ref 'make-tray tbl)
                            #:icon icon-path
                            #:tooltip tooltip
                            #:menu items
                            #:on-event on-event)))])
    (tray (detected-backend)
          ((ref 'make-tray (load-backend!))
           #:icon icon-path
           #:tooltip tooltip
           #:menu items
           #:on-event on-event))))

(define (detected-backend)
  (case (system-type 'os)
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]
    [else 'stub]))

(define (tray-set-tooltip! t tooltip)
  (check-tray 'tray-set-tooltip! t)
  (unless (string? tooltip)
    (raise-argument-error 'tray-set-tooltip! "string?" tooltip))
  ((ref 'set-tooltip! (table-for-tray t)) (tray-handle t) tooltip))

(define (tray-set-icon! t icon-path)
  (check-tray 'tray-set-icon! t)
  (check-icon 'tray-set-icon! icon-path)
  ((ref 'set-icon! (table-for-tray t)) (tray-handle t) icon-path))

(define (tray-set-menu! t items)
  (check-tray 'tray-set-menu! t)
  (check-items 'tray-set-menu! items)
  ((ref 'set-menu! (table-for-tray t)) (tray-handle t) items))

(define (tray-close t)
  (check-tray 'tray-close t)
  ((ref 'close (table-for-tray t)) (tray-handle t)))
