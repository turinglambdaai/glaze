#lang racket/base

;; glaze/hotkey — system-wide hotkeys. A hotkey is modifiers + a key, in a
;; platform-neutral shape; each backend maps it onto the native mechanism
;; (Win32 RegisterHotKey, Carbon RegisterEventHotKey, X11 XGrabKey). Same
;; platform-dispatch shape as glaze/sys, glaze/tray, and glaze/webview.

(require racket/list)

(provide hotkey
         hotkey?
         hotkey-mods
         hotkey-key
         make-hotkey
         hotkey=?
         hotkey-keys
         hotkey-modifiers
         hotkey-supported?
         hotkey-register!
         hotkey-unregister!
         hotkey-unregister-all!
         hotkey-registered?)

;; ---- model ----

;; Modifiers in canonical order. `cmd` is the Command key on macOS and the
;; Super/Windows key elsewhere; `alt` is Option on macOS.
(define hotkey-modifiers '(cmd ctrl alt shift))

;; Canonical key symbols: letters, digits, F1..F24, numpad keys, and named
;; keys matching the USB keyboard usage / Tauri Code vocabulary. Backends
;; translate these to VK codes, Carbon key codes, or X keysyms.
(define hotkey-keys
  (append (for/list ([c (in-string "ABCDEFGHIJKLMNOPQRSTUVWXYZ")])
            (string->symbol (string c)))
          (for/list ([c (in-string "0123456789")])
            (string->symbol (string c)))
          (for/list ([n (in-range 1 25)])
            (string->symbol (format "F~a" n)))
          '(Space Tab
                  Enter
                  Escape
                  Backspace
                  Delete
                  Insert
                  Home
                  End
                  PageUp
                  PageDown
                  Up
                  Down
                  Left
                  Right
                  CapsLock
                  NumLock
                  ScrollLock
                  PrintScreen
                  Pause
                  Comma
                  Period
                  Slash
                  Backslash
                  Semicolon
                  Quote
                  Backquote
                  BracketLeft
                  BracketRight
                  Minus
                  Equal
                  Numpad0
                  Numpad1
                  Numpad2
                  Numpad3
                  Numpad4
                  Numpad5
                  Numpad6
                  Numpad7
                  Numpad8
                  Numpad9
                  NumpadAdd
                  NumpadSubtract
                  NumpadMultiply
                  NumpadDivide
                  NumpadEnter
                  NumpadDecimal)))

(struct hotkey (mods key) #:transparent)

(define (make-hotkey mods key)
  (unless (and (list? mods) (andmap (lambda (m) (memq m hotkey-modifiers)) mods))
    (raise-argument-error 'make-hotkey "list of hotkey modifiers" mods))
  (unless (memq key hotkey-keys)
    (raise-argument-error 'make-hotkey "known hotkey key" key))
  (hotkey (sort (remove-duplicates mods)
                (lambda (a b) (< (index-of hotkey-modifiers a) (index-of hotkey-modifiers b))))
          key))

(define (hotkey=? a b)
  (and (equal? (hotkey-mods a) (hotkey-mods b)) (eq? (hotkey-key a) (hotkey-key b))))

;; ---- platform backend dispatch ----

(define (backend-module-path)
  (case (system-type 'os)
    [(macosx) 'glaze/hotkey/hotkey-macos]
    [(windows) 'glaze/hotkey/hotkey-windows]
    [(unix) 'glaze/hotkey/hotkey-linux]
    [else 'glaze/hotkey/hotkey-stub]))

(define backend-procs #f)

(define (load-backend!)
  (unless backend-procs
    (set! backend-procs (make-hash))
    (define mod (backend-module-path))
    (for ([name (in-list '(supported? register! unregister! unregister-all! registered?))])
      (hash-set! backend-procs name (dynamic-require mod name))))
  backend-procs)

(define (ref name)
  (hash-ref (load-backend!) name))

(define (hotkey-supported?)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'supported?))))

;; Register a system-wide hotkey. The thunk runs on a backend thread every
;; time the combination is pressed anywhere in the session. Returns #t when
;; the backend accepted the registration.
(define (hotkey-register! hk thunk)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'register!) hk thunk)))

(define (hotkey-unregister! hk)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'unregister!) hk)))

;; Release every hotkey this process registered. Returns #t when the backend
;; ran the sweep (even if nothing was registered).
(define (hotkey-unregister-all!)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'unregister-all!))))

(define (hotkey-registered? hk)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((ref 'registered?) hk)))
