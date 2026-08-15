#lang racket/base

;; glaze/sys — desktop-system integrations beyond the tray: clipboard,
;; notifications, opening/revealing paths, single-instance locking, and
;; (via the webview module) window controls. Same platform-dispatch shape
;; as glaze/tray and glaze/webview.

(require racket/file
         racket/system)

(provide sys-supported?
         clipboard-set!
         clipboard-get
         notify!
         open-path
         reveal-path
         single-instance?)

;; ---- platform backend dispatch ----

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

;; ---- clipboard ----

;; Place text on the system clipboard. Returns #t on success.
(define (clipboard-set! text)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'clipboard-set!) text)))

;; Read text from the system clipboard; "" when empty/absent.
(define (clipboard-get)
  (with-handlers ([exn:fail? (lambda (e) "")])
    ((ref 'clipboard-get))))

;; ---- notifications ----

;; Show a desktop notification. Returns #t if a delivery mechanism ran
;; (delivery itself is best-effort — OS settings may suppress it).
(define (notify! title [body ""] #:subtitle [subtitle ""])
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'notify!) title body subtitle)))

;; ---- opening files / URLs ----

;; Open a path or URL with the OS default handler. Returns #t if the
;; launcher subprocess succeeded.
(define (open-path p)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'open-path) (if (path? p) (path->string p) p))))

;; Reveal a file in Finder / Explorer / the file manager (selecting it).
(define (reveal-path p)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'reveal-path) (if (path? p) (path->string p) p))))

;; ---- single instance ----

;; Adjudicate "am I the first instance of app-id?" without leaving files
;; behind: derive a deterministic TCP port from the id and hold a listener
;; on it for the process lifetime. The second instance's bind fails.
;; Returns #t for the first instance, #f if another process already holds
;; the lock. (A firewall prompt is possible on first run on some systems.)
(define (single-instance? app-id)
  (define h (equal-hash-code app-id))
  (define port (+ 49152 (modulo h 16384)))
  (with-handlers ([exn:fail:network? (lambda (e) #f)])
    (define cust (make-custodian))
    (parameterize ([current-custodian cust])
      (tcp-listen port 1 #f "127.0.0.1"))
    #t))

(require racket/tcp)
