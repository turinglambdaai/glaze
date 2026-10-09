#lang racket/base

;; Windows hotkey backend — Win32 RegisterHotKey against a message-only
;; window. WM_HOTKEY arrives posted to that window, so the single dispatch
;; point is the window procedure: whichever pump PeekMessages first (ours
;; here, or a glaze webview pump in the same process on the same OS thread)
;; dispatches into the same wndproc and the thunk fires exactly once.

(require ffi/unsafe
         racket/list
         "../main.rkt")

(provide supported?
         register!
         unregister!
         unregister-all!
         registered?)

(define user32 (ffi-lib "user32"))
(define kernel32 (ffi-lib "kernel32"))

(define RegisterHotKey
  (get-ffi-obj "RegisterHotKey" user32 (_fun _pointer _int _uint _uint -> _bool) (lambda () #f)))
(define UnregisterHotKey
  (get-ffi-obj "UnregisterHotKey" user32 (_fun _pointer _int -> _bool) (lambda () #f)))
(define RegisterClassExW
  (get-ffi-obj "RegisterClassExW" user32 (_fun _pointer -> _ushort) (lambda () #f)))
(define CreateWindowExW
  (get-ffi-obj "CreateWindowExW"
               user32
               (_fun _uint
                     _pointer
                     _pointer
                     _uint
                     _int
                     _int
                     _int
                     _int
                     _intptr
                     _pointer
                     _pointer
                     _pointer
                     ->
                     _pointer)
               (lambda () #f)))
(define DefWindowProcW
  (get-ffi-obj "DefWindowProcW"
               user32
               (_fun _pointer _uint _uintptr _intptr -> _intptr)
               (lambda () #f)))
(define PeekMessageW
  (get-ffi-obj "PeekMessageW"
               user32
               (_fun _pointer _pointer _uint _uint _uint -> _bool)
               (lambda () #f)))
(define TranslateMessage
  (get-ffi-obj "TranslateMessage" user32 (_fun _pointer -> _bool) (lambda () #f)))
(define DispatchMessageW
  (get-ffi-obj "DispatchMessageW" user32 (_fun _pointer -> _intptr) (lambda () #f)))
(define GetModuleHandleW
  (get-ffi-obj "GetModuleHandleW" kernel32 (_fun _pointer -> _pointer) (lambda () #f)))

(define-cstruct _WNDCLASSEXW
                ([cbSize _uint] [style _uint]
                                [lpfnWndProc _pointer]
                                [cbClsExtra _int]
                                [cbWndExtra _int]
                                [hInstance _pointer]
                                [hIcon _pointer]
                                [hCursor _pointer]
                                [hbrBackground _pointer]
                                [lpszMenuName _pointer]
                                [lpszClassName _pointer]
                                [hIconSm _pointer]))
(define-cstruct _MSG
                ([hwnd _pointer] [message _uint]
                                 [wParam _uintptr]
                                 [lParam _intptr]
                                 [time _uint]
                                 [pt _int]
                                 [pt2 _int]))

(define WM_HOTKEY #x0312)
(define PM_REMOVE 1)
;; Message-only window: invisible, not enumerated, receives posted messages.
(define HWND_MESSAGE -3)
(define class-name #"GlazeHotkey")

;; ---- key tables ----

(define vk-table
  (make-immutable-hash (append (for/list ([i (in-range 65 91)])
                                 (cons (string->symbol (string (integer->char i))) (+ #x40 (- i 64))))
                               (for/list ([i (in-range 48 58)])
                                 (cons (string->symbol (string (integer->char i))) i))
                               (for/list ([n (in-range 1 25)])
                                 (cons (string->symbol (format "F~a" n)) (+ #x6F n)))
                               (list (cons 'Space #x20)
                                     (cons 'Tab #x09)
                                     (cons 'Enter #x0D)
                                     (cons 'Escape #x1B)
                                     (cons 'Backspace #x08)
                                     (cons 'Delete #x2E)
                                     (cons 'Insert #x2D)
                                     (cons 'Home #x24)
                                     (cons 'End #x23)
                                     (cons 'PageUp #x21)
                                     (cons 'PageDown #x22)
                                     (cons 'Up #x26)
                                     (cons 'Down #x28)
                                     (cons 'Left #x25)
                                     (cons 'Right #x27)
                                     (cons 'CapsLock #x14)
                                     (cons 'NumLock #x90)
                                     (cons 'ScrollLock #x91)
                                     (cons 'PrintScreen #x2C)
                                     (cons 'Pause #x13)
                                     (cons 'Comma #xBC)
                                     (cons 'Period #xBE)
                                     (cons 'Slash #xBF)
                                     (cons 'Backslash #xDC)
                                     (cons 'Semicolon #xBA)
                                     (cons 'Quote #xDE)
                                     (cons 'Backquote #xC0)
                                     (cons 'BracketLeft #xDB)
                                     (cons 'BracketRight #xDD)
                                     (cons 'Minus #xBD)
                                     (cons 'Equal #xBB)
                                     (cons 'Numpad0 #x60)
                                     (cons 'Numpad1 #x61)
                                     (cons 'Numpad2 #x62)
                                     (cons 'Numpad3 #x63)
                                     (cons 'Numpad4 #x64)
                                     (cons 'Numpad5 #x65)
                                     (cons 'Numpad6 #x66)
                                     (cons 'Numpad7 #x67)
                                     (cons 'Numpad8 #x68)
                                     (cons 'Numpad9 #x69)
                                     (cons 'NumpadAdd #x6B)
                                     (cons 'NumpadSubtract #x6D)
                                     (cons 'NumpadMultiply #x6A)
                                     (cons 'NumpadDivide #x6F)
                                     (cons 'NumpadEnter #x0D)
                                     (cons 'NumpadDecimal #x6E)))))

;; MOD_ALT 1, MOD_CONTROL 2, MOD_SHIFT 4, MOD_WIN 8.
(define mod-flags '((cmd . 8) (ctrl . 2) (alt . 1) (shift . 4)))

(define (mods->flags mods)
  (for/sum ([m (in-list mods)]) (cdr (assq m mod-flags))))

;; ---- registry ----

(define sema (make-semaphore 1))
(define by-id (make-hash)) ; id -> (list hotkey thunk)
(define by-hotkey (make-hash)) ; (list mods key) -> id
(define next-id 1)

(define (hk-key hk)
  (list (hotkey-mods hk) (hotkey-key hk)))

(define (lookup-thunk id)
  (call-with-semaphore sema
                       (lambda ()
                         (define entry (hash-ref by-id id #f))
                         (and entry (second entry)))))

;; The wndproc is the single dispatch point for hotkey events.
(define wndproc-cptr
  (function-ptr (lambda (hwnd msg w l)
                  (cond
                    [(= msg WM_HOTKEY)
                     (define thunk (lookup-thunk w))
                     (when thunk
                       (thunk))
                     0]
                    [else (DefWindowProcW hwnd msg w l)]))
                (_fun _pointer _uint _uintptr _intptr -> _intptr)))

(define state (box #f)) ; (vector hwnd pump-thread)

(define (log fmt . args)
  (apply fprintf (current-error-port) (string-append "[glaze-hotkey-win] " fmt "\n") args))

(define (ensure-manager!)
  (call-with-semaphore
   sema
   (lambda ()
     (define st (unbox state))
     (or st
         (let ()
           (define instance (GetModuleHandleW #f))
           (define wc
             (cast (malloc (ctype-sizeof _WNDCLASSEXW) 'raw _pointer) _pointer _WNDCLASSEXW-pointer))
           (memset wc 0 (ctype-sizeof _WNDCLASSEXW))
           (set-WNDCLASSEXW-cbSize! wc (ctype-sizeof _WNDCLASSEXW))
           (set-WNDCLASSEXW-lpfnWndProc! wc wndproc-cptr)
           (set-WNDCLASSEXW-hInstance! wc instance)
           (set-WNDCLASSEXW-lpszClassName! wc class-name)
           (RegisterClassExW wc)
           (define hwnd
             (CreateWindowExW 0 class-name class-name 0 0 0 0 0 HWND_MESSAGE #f instance #f))
           (unless hwnd
             (log "message window creation failed"))
           (define st
             (vector hwnd
                     (thread (lambda ()
                               (let loop ()
                                 (define msg (malloc (ctype-sizeof _MSG) 'atomic))
                                 (when (PeekMessageW msg hwnd 0 0 PM_REMOVE)
                                   (TranslateMessage msg)
                                   (DispatchMessageW msg))
                                 (sleep 0.01)
                                 (loop))))))
           (set-box! state st)
           st)))))

(define (supported?)
  (and (eq? (system-type 'os) 'windows)
       RegisterHotKey
       UnregisterHotKey
       CreateWindowExW
       PeekMessageW
       #t))

(define (register! hk thunk)
  (and (supported?)
       (let ()
         (define st (ensure-manager!))
         (define hwnd (vector-ref st 0))
         (and hwnd
              (call-with-semaphore
               sema
               (lambda ()
                 (define k (hk-key hk))
                 (cond
                   [(hash-ref by-hotkey k #f) #f] ; already registered here
                   [else
                    (define id next-id)
                    (define vk (hash-ref vk-table (hotkey-key hk) #f))
                    (and vk
                         (RegisterHotKey hwnd id (mods->flags (hotkey-mods hk)) vk)
                         (begin
                           (set! next-id (add1 id))
                           (hash-set! by-id id (list hk thunk))
                           (hash-set! by-hotkey k id)
                           #t))])))))))

(define (unregister! hk)
  (and (supported?)
       (let ()
         (define st (unbox state))
         (define hwnd (and st (vector-ref st 0)))
         (and hwnd
              (call-with-semaphore sema
                                   (lambda ()
                                     (define id (hash-ref by-hotkey (hk-key hk) #f))
                                     (and id
                                          (begin
                                            (hash-remove! by-id id)
                                            (hash-remove! by-hotkey (hk-key hk))
                                            (UnregisterHotKey hwnd id)))))))))

(define (unregister-all!)
  (and (supported?)
       (let ()
         (define st (unbox state))
         (define hwnd (and st (vector-ref st 0)))
         (and hwnd
              (call-with-semaphore sema
                                   (lambda ()
                                     (for ([id (in-list (hash-keys by-id))])
                                       (UnregisterHotKey hwnd id))
                                     (hash-clear! by-id)
                                     (hash-clear! by-hotkey)
                                     #t))))))

(define (registered? hk)
  (call-with-semaphore sema (lambda () (and (hash-ref by-hotkey (hk-key hk) #f) #t))))
