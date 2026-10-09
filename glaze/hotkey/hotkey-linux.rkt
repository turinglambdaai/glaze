#lang racket/base

;; Linux hotkey backend — X11 XGrabKey on the root window through a private
;; display connection. A pump thread polls XPending/XNextEvent; grabs are
;; validated by counting async protocol errors around an XSync. On Wayland
;; sessions without XWayland the display open fails and every call reports
;; failure. Exact-modifier grabs: extra latch keys (Caps/Num Lock) suppress
;; the event, matching XGrabKey semantics.

(require ffi/unsafe
         racket/list
         "../ffi-discovery.rkt"
         "../main.rkt")

(provide supported?
         register!
         unregister!
         unregister-all!
         registered?)

(define x11 (ffi-lib* "libX11" '("6" "")))

(define XOpenDisplay (get-ffi-obj "XOpenDisplay" x11 (_fun _pointer -> _pointer) (lambda () #f)))
(define XCloseDisplay (get-ffi-obj "XCloseDisplay" x11 (_fun _pointer -> _int) (lambda () #f)))
(define XDefaultRootWindow
  (get-ffi-obj "XDefaultRootWindow" x11 (_fun _pointer -> _ulong) (lambda () #f)))
(define XKeysymToKeycode
  (get-ffi-obj "XKeysymToKeycode" x11 (_fun _pointer _ulong -> _int) (lambda () #f)))
(define XGrabKey
  (get-ffi-obj "XGrabKey"
               x11
               (_fun _pointer _int _uint _ulong _bool _int _int -> _void)
               (lambda () #f)))
(define XUngrabKey
  (get-ffi-obj "XUngrabKey" x11 (_fun _pointer _int _uint _ulong -> _void) (lambda () #f)))
(define XPending (get-ffi-obj "XPending" x11 (_fun _pointer -> _int) (lambda () #f)))
(define XNextEvent (get-ffi-obj "XNextEvent" x11 (_fun _pointer _pointer -> _int) (lambda () #f)))
(define XSync (get-ffi-obj "XSync" x11 (_fun _pointer _bool -> _int) (lambda () #f)))
(define XSetErrorHandler
  (get-ffi-obj "XSetErrorHandler" x11 (_fun _fpointer -> _fpointer) (lambda () #f)))

;; X modifier masks (X.h): Shift 1, Control 4, Mod1 (Alt) 8, Mod4 (Super) 64.
(define mod-flags '((cmd . 64) (ctrl . 4) (alt . 8) (shift . 1)))

(define (mods->flags mods)
  (for/sum ([m (in-list mods)]) (cdr (assq m mod-flags))))

;; X11 keysyms for the canonical keys. Letters are lowercase (the keycode is
;; physical, shift is a modifier), digits are ASCII, F-keys start at #xFFBE.
(define keysym-table
  (make-immutable-hash (append (for/list ([i (in-range 97 123)])
                                 (cons (string->symbol (string (integer->char (- i 32)))) i))
                               (for/list ([i (in-range 48 58)])
                                 (cons (string->symbol (string (integer->char i))) i))
                               (for/list ([n (in-range 1 25)])
                                 (cons (string->symbol (format "F~a" n)) (+ #xFFBD n)))
                               (list (cons 'Space #x020)
                                     (cons 'Tab #xFF09)
                                     (cons 'Enter #xFF0D)
                                     (cons 'Escape #xFF1B)
                                     (cons 'Backspace #xFF08)
                                     (cons 'Delete #xFFFF)
                                     (cons 'Insert #xFF63)
                                     (cons 'Home #xFF50)
                                     (cons 'End #xFF57)
                                     (cons 'PageUp #xFF55)
                                     (cons 'PageDown #xFF56)
                                     (cons 'Left #xFF51)
                                     (cons 'Up #xFF52)
                                     (cons 'Right #xFF53)
                                     (cons 'Down #xFF54)
                                     (cons 'CapsLock #xFFE5)
                                     (cons 'NumLock #xFF7F)
                                     (cons 'ScrollLock #xFF14)
                                     (cons 'PrintScreen #xFF61)
                                     (cons 'Pause #xFF13)
                                     (cons 'Comma #x2C)
                                     (cons 'Period #x2E)
                                     (cons 'Slash #x2F)
                                     (cons 'Backslash #x5C)
                                     (cons 'Semicolon #x3B)
                                     (cons 'Quote #x27)
                                     (cons 'Backquote #x60)
                                     (cons 'BracketLeft #x5B)
                                     (cons 'BracketRight #x5D)
                                     (cons 'Minus #x2D)
                                     (cons 'Equal #x3D)
                                     (cons 'Numpad0 #xFFB0)
                                     (cons 'Numpad1 #xFFB1)
                                     (cons 'Numpad2 #xFFB2)
                                     (cons 'Numpad3 #xFFB3)
                                     (cons 'Numpad4 #xFFB4)
                                     (cons 'Numpad5 #xFFB5)
                                     (cons 'Numpad6 #xFFB6)
                                     (cons 'Numpad7 #xFFB7)
                                     (cons 'Numpad8 #xFFB8)
                                     (cons 'Numpad9 #xFFB9)
                                     (cons 'NumpadAdd #xFFAB)
                                     (cons 'NumpadSubtract #xFFAD)
                                     (cons 'NumpadMultiply #xFFAA)
                                     (cons 'NumpadDivide #xFFAF)
                                     (cons 'NumpadEnter #xFF8D)
                                     (cons 'NumpadDecimal #xFFAE)))))

;; XEvent layout we read: type (int) at 0; KeyPress adds `state` (unsigned)
;; at offset 80 and `keycode` (unsigned) at offset 84 on LP64.
(define KeyPress 2)
(define state-offset 80)
(define keycode-offset 84)
(define xevent-size 256)

;; ---- state ----

(define sema (make-semaphore 1))
(define display-box (box #f)) ; private Display*
(define root-box (box #f))
(define error-count (box 0)) ; async protocol errors seen by our handler
(define by-combo (make-hash)) ; (list keycode mods) -> thunk
(define pump-box (box #f))

(define (hk-key hk)
  (list (hotkey-mods hk) (hotkey-key hk)))

;; Suppress the default Xlib behavior (print + exit) and count errors so
;; grabs can detect conflicts (BadAccess = another client grabbed it).
(define error-handler-cptr
  (and XSetErrorHandler
       (function-ptr (lambda (dpy error-event)
                       (set-box! error-count (add1 (unbox error-count)))
                       0)
                     (_fun _pointer _pointer -> _int))))

(define (log fmt . args)
  (apply fprintf (current-error-port) (string-append "[glaze-hotkey-linux] " fmt "\n") args))

(define (ensure-display!)
  (call-with-semaphore sema
                       (lambda ()
                         (or (unbox display-box)
                             (let ()
                               (when error-handler-cptr
                                 (XSetErrorHandler error-handler-cptr))
                               (define dpy (and XOpenDisplay (XOpenDisplay #f)))
                               (cond
                                 [(not dpy)
                                  (log "XOpenDisplay failed (no X server?)")
                                  #f]
                                 [else
                                  (define root (XDefaultRootWindow dpy))
                                  (set-box! root-box root)
                                  (set-box! display-box dpy)
                                  dpy]))))))

(define (ensure-pump!)
  (unless (unbox pump-box)
    (set-box! pump-box
              (thread (lambda ()
                        (let loop ()
                          (define dpy (unbox display-box))
                          (when (and dpy XPending XNextEvent)
                            (when (> (XPending dpy) 0)
                              (define ev (malloc xevent-size 'atomic))
                              (when (> (XNextEvent dpy ev) -1)
                                (define type (ptr-ref (ptr-add ev 0) _int32 0))
                                (when (= type KeyPress)
                                  (define keycode (ptr-ref (ptr-add ev keycode-offset) _uint32 0))
                                  (define state (ptr-ref (ptr-add ev state-offset) _uint32 0))
                                  (define thunk
                                    (call-with-semaphore
                                     sema
                                     (lambda () (hash-ref by-combo (list keycode state) #f))))
                                  (when thunk
                                    (thunk)))))
                            (sleep 0.01))
                          (loop))))))
  (unbox pump-box))

(define (supported?)
  (and (eq? (system-type 'os) 'unix) XOpenDisplay XGrabKey #t))

(define (register! hk thunk)
  (and (supported?)
       (let ()
         (define dpy (ensure-display!))
         (and dpy
              (let ()
                (define sym (hash-ref keysym-table (hotkey-key hk) #f))
                (define keycode (and sym (XKeysymToKeycode dpy sym)))
                (and keycode
                     (> keycode 0)
                     (let ()
                       (define root (unbox root-box))
                       (define flags (mods->flags (hotkey-mods hk)))
                       (call-with-semaphore
                        sema
                        (lambda ()
                          (cond
                            [(hash-ref by-combo (list keycode flags) #f) #f]
                            [else
                             (define before (unbox error-count))
                             (XGrabKey dpy keycode flags root #f 1 1) ; GrabModeAsync
                             (XSync dpy #f)
                             (cond
                               [(> (unbox error-count) before) #f]
                               [else
                                (hash-set! by-combo (list keycode flags) thunk)
                                (ensure-pump!)
                                #t])]))))))))))

(define (unregister! hk)
  (and (supported?)
       (let ()
         (define dpy (unbox display-box))
         (and dpy
              (let ()
                (define sym (hash-ref keysym-table (hotkey-key hk) #f))
                (define keycode (and sym (XKeysymToKeycode dpy sym)))
                (and keycode
                     (> keycode 0)
                     (let ()
                       (define flags (mods->flags (hotkey-mods hk)))
                       (call-with-semaphore sema
                                            (lambda ()
                                              (cond
                                                [(hash-ref by-combo (list keycode flags) #f)
                                                 (hash-remove! by-combo (list keycode flags))
                                                 (XUngrabKey dpy keycode flags (unbox root-box))
                                                 (XSync dpy #f)
                                                 #t]
                                                [else #f]))))))))))

(define (unregister-all!)
  (and (supported?)
       (let ()
         (define dpy (unbox display-box))
         (and dpy
              (call-with-semaphore sema
                                   (lambda ()
                                     (for ([combo (in-list (hash-keys by-combo))])
                                       (XUngrabKey dpy (first combo) (second combo) (unbox root-box)))
                                     (hash-clear! by-combo)
                                     (XSync dpy #f)
                                     #t))))))

(define (registered? hk)
  (let ()
    (define dpy (unbox display-box))
    (and dpy
         (let ()
           (define sym (hash-ref keysym-table (hotkey-key hk) #f))
           (define keycode (and sym (XKeysymToKeycode dpy sym)))
           (and keycode
                (> keycode 0)
                (call-with-semaphore
                 sema
                 (lambda ()
                   (and (hash-ref by-combo (list keycode (mods->flags (hotkey-mods hk))) #f)
                        #t))))))))
