#lang racket/base

;; Public tray API. Dispatches to a platform-specific backend based on
;; (system-type 'os):
;;   - 'windows  -> tray-windows.rkt  (Shell_NotifyIconW via ffi/unsafe)
;;   - 'macosx   -> tray-macos.rkt    (NSStatusItem via ffi/unsafe/objc) [stub for now]
;;   - 'unix     -> trayay-linux.rkt  (libayatana-appindicator via ffi/unsafe) [stub for now]
;;
;; Every backend exports the SAME procedure names (make-tray, set-tooltip!,
;; set-icon!, set-menu!, close, supported?) and performs its own platform /
;; library gating. If a backend's make-tray raises (native deps missing or not
;; implemented), the dispatcher catches it, warns, and retries against the stub
;; so callers always get a usable (possibly inert) handle.

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
         ;; re-export protocol surface for menu construction
         (all-from-out "tray-protocol.rkt"))

;; A tray handle wraps the backend-specific handle together with the backend
;; tag, so `tray-backend` introspection (and tests) can tell which
;; implementation is live without poking native resources.
(struct tray (backend handle) #:transparent)

;; Pick the backend module path for the current OS.
(define (backend-module-path)
  (case (system-type 'os)
    [(windows) 'glaze/tray/tray-windows]
    [(macosx) 'glaze/tray/tray-macos]
    [(unix) 'glaze/tray/tray-linux]
    [else 'glaze/tray/tray-stub]))

;; Cached proc table for the active backend: name symbol -> procedure. We load
;; lazily on first use so requiring glaze/tray on a host platform never drags
;; in another platform's backend (which could fail at require time).
(define backend-procs #f)

(define (load-backend!)
  (unless backend-procs
    (set! backend-procs (make-hash))
    (define mod (backend-module-path))
    (for ([name (in-list '(make-tray set-tooltip! set-icon! set-menu! close supported?))])
      (hash-set! backend-procs name (dynamic-require mod name))))
  backend-procs)

;; Load the stub's procs under a separate table, used for fallback.
(define (load-stub-procs)
  (define tbl (make-hash))
  (for ([name (in-list '(make-tray set-tooltip! set-icon! set-menu! close supported?))])
    ;; Stub exports use a `stub:` prefix.
    (hash-set! tbl
               name
               (dynamic-require 'glaze/tray/tray-stub (string->symbol (format "stub:~a" name)))))
  tbl)

(define (ref name tbl)
  (hash-ref tbl name))

(define (tray-supported?)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'supported? (load-backend!)))))

;; Track whether we have fallen back to the stub so subsequent mutators also
;; use the stub procs (per-process: a host with no native backend stays inert).
(define using-stub? (box #f))

(define (current-table)
  (if (unbox using-stub?)
      (load-stub-procs)
      (load-backend!)))

(define (make-tray #:icon icon-path
                   #:tooltip tooltip
                   #:menu items
                   #:on-event [on-event (lambda (e) (void))])
  (with-handlers ([exn:fail? (lambda (e)
                               (fprintf (current-error-port)
                                        "[glaze] tray backend unavailable (~a); using no-op stub.\n"
                                        (exn-message e))
                               (set-box! using-stub? #t)
                               (define tbl (load-stub-procs))
                               (tray 'stub
                                     ((ref 'make-tray tbl) #:icon icon-path
                                                           #:tooltip tooltip
                                                           #:menu items
                                                           #:on-event on-event)))])
    (tray (detected-backend)
          ((ref 'make-tray (load-backend!)) #:icon icon-path
                                            #:tooltip tooltip
                                            #:menu items
                                            #:on-event on-event))))

;; Backend tag for tagging purposes (does not force a reload).
(define (detected-backend)
  (case (system-type 'os)
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]
    [else 'stub]))

(define (tray-set-tooltip! t tooltip)
  ((ref 'set-tooltip! (current-table)) (tray-handle t) tooltip))
(define (tray-set-icon! t icon-path)
  ((ref 'set-icon! (current-table)) (tray-handle t) icon-path))
(define (tray-set-menu! t items)
  ((ref 'set-menu! (current-table)) (tray-handle t) items))
(define (tray-close t)
  ((ref 'close (current-table)) (tray-handle t)))
