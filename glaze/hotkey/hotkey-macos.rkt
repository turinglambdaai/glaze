#lang racket/base

;; macOS hotkey backend — Carbon RegisterEventHotKey (HIToolbox). A handler
;; on the application target receives kEventHotKeyPressed; a pump thread
;; calls ReceiveNextEvent filtered to exactly that event kind, so it never
;; competes with an NSApplication event loop for window events. Either pump
;; delivering the event runs the same installed handler, and the thunk fires
;; exactly once.

(require ffi/unsafe
         racket/list
         "../main.rkt")

(provide supported?
         register!
         unregister!
         unregister-all!
         registered?)

(define hitoolbox
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox")))

(define-cstruct _EventHotKeyID ([signature _uint32] [id _uint32]))
(define-cstruct _EventTypeSpec ([eventClass _uint32] [eventKind _uint32]))

(define RegisterEventHotKey
  (and hitoolbox
       (get-ffi-obj "RegisterEventHotKey"
                    hitoolbox
                    (_fun _uint32 _uint32 _EventHotKeyID _uint32 _pointer (_ptr o _pointer) -> _int32)
                    (lambda () #f))))
(define UnregisterEventHotKey
  (and hitoolbox
       (get-ffi-obj "UnregisterEventHotKey" hitoolbox (_fun _pointer -> _int32) (lambda () #f))))
(define GetApplicationEventTarget
  (and hitoolbox
       (get-ffi-obj "GetApplicationEventTarget" hitoolbox (_fun -> _pointer) (lambda () #f))))
(define InstallEventHandler
  (and hitoolbox
       (get-ffi-obj "InstallEventHandler"
                    hitoolbox
                    (_fun _pointer _fpointer _uint32 _pointer _pointer (_ptr o _pointer) -> _int32)
                    (lambda () #f))))
(define GetEventParameter
  (and hitoolbox
       (get-ffi-obj "GetEventParameter"
                    hitoolbox
                    (_fun _pointer _uint32 _uint32 _pointer _ulong _pointer _pointer -> _int32)
                    (lambda () #f))))
(define ReceiveNextEvent
  (and hitoolbox
       (get-ffi-obj "ReceiveNextEvent"
                    hitoolbox
                    (_fun _uint32 _pointer _double _bool (_ptr o _pointer) -> _int32)
                    (lambda () #f))))
(define SendEventToEventTarget
  (and hitoolbox
       (get-ffi-obj "SendEventToEventTarget"
                    hitoolbox
                    (_fun _pointer _pointer -> _int32)
                    (lambda () #f))))
(define ReleaseEvent
  (and hitoolbox (get-ffi-obj "ReleaseEvent" hitoolbox (_fun _pointer -> _void) (lambda () #f))))

(define noErr 0)
;; 'keyb' / '----' / 'hkid' as FourCharCode values.
(define kEventClassKeyboard #x6B657962)
(define kEventHotKeyPressed 1)
(define kEventParamDirectObject #x2D2D2D2D)
(define typeEventHotKeyID #x686B6964)
(define hotkey-signature #x676C7A65) ; 'glze'

;; Carbon modifier masks (Events.h).
(define mod-flags '((cmd . #x0100) (shift . #x0200) (alt . #x0800) (ctrl . #x1000)))

(define (mods->flags mods)
  (for/sum ([m (in-list mods)]) (cdr (assq m mod-flags))))

;; kVK_ANSI_* key codes (HIToolbox/Events.h).
(define vk-table
  (make-immutable-hash (list (cons 'A #x00)
                             (cons 'S #x01)
                             (cons 'D #x02)
                             (cons 'F #x03)
                             (cons 'H #x04)
                             (cons 'G #x05)
                             (cons 'Z #x06)
                             (cons 'X #x07)
                             (cons 'C #x08)
                             (cons 'V #x09)
                             (cons 'B #x0B)
                             (cons 'Q #x0C)
                             (cons 'W #x0D)
                             (cons 'E #x0E)
                             (cons 'R #x0F)
                             (cons 'Y #x10)
                             (cons 'T #x11)
                             (cons 'N1 #x12)
                             (cons 'N2 #x13)
                             (cons 'N3 #x14)
                             (cons 'N4 #x15)
                             (cons '0 #x1D)
                             (cons '1 #x12)
                             (cons '2 #x13)
                             (cons '3 #x14)
                             (cons '4 #x15)
                             (cons '5 #x17)
                             (cons '6 #x16)
                             (cons '7 #x1A)
                             (cons '8 #x1C)
                             (cons '9 #x19)
                             (cons 'Equal #x18)
                             (cons 'Minus #x1B)
                             (cons 'BracketRight #x1E)
                             (cons 'BracketLeft #x21)
                             (cons 'Quote #x29)
                             (cons 'Comma #x2B)
                             (cons 'Slash #x2C)
                             (cons 'Semicolon #x27)
                             (cons 'Period #x2F)
                             (cons 'Backquote #x32)
                             (cons 'Space #x31)
                             (cons 'Tab #x30)
                             (cons 'Return #x24)
                             (cons 'Escape #x35)
                             (cons 'Backspace #x33)
                             (cons 'Delete #x75)
                             (cons 'Insert #x72)
                             (cons 'Home #x73)
                             (cons 'End #x77)
                             (cons 'PageUp #x74)
                             (cons 'PageDown #x79)
                             (cons 'Left #x7B)
                             (cons 'Right #x7C)
                             (cons 'Down #x7D)
                             (cons 'Up #x7E)
                             (cons 'CapsLock #x39)
                             (cons 'NumLock #x47)
                             (cons 'ScrollLock #x6B)
                             (cons 'PrintScreen #x69)
                             (cons 'Pause #x71)
                             (cons 'F1 #x7A)
                             (cons 'F2 #x78)
                             (cons 'F3 #x63)
                             (cons 'F4 #x76)
                             (cons 'F5 #x60)
                             (cons 'F6 #x61)
                             (cons 'F7 #x62)
                             (cons 'F8 #x64)
                             (cons 'F9 #x65)
                             (cons 'F10 #x6D)
                             (cons 'F11 #x67)
                             (cons 'F12 #x6F)
                             (cons 'F13 #x69)
                             (cons 'F14 #x6B)
                             (cons 'F15 #x71)
                             (cons 'F16 #x6A)
                             (cons 'F17 #x40)
                             (cons 'F18 #x4F)
                             (cons 'F19 #x50)
                             (cons 'F20 #x5A)
                             (cons 'Numpad0 #x52)
                             (cons 'Numpad1 #x53)
                             (cons 'Numpad2 #x54)
                             (cons 'Numpad3 #x55)
                             (cons 'Numpad4 #x56)
                             (cons 'Numpad5 #x57)
                             (cons 'Numpad6 #x58)
                             (cons 'Numpad7 #x59)
                             (cons 'Numpad8 #x5B)
                             (cons 'Numpad9 #x5C)
                             (cons 'NumpadDecimal #x41)
                             (cons 'NumpadMultiply #x43)
                             (cons 'NumpadAdd #x45)
                             (cons 'NumpadDivide #x4B)
                             (cons 'NumpadEnter #x4C)
                             (cons 'NumpadSubtract #x4E))))

;; ---- registry ----

(define sema (make-semaphore 1))
(define by-id (make-hash)) ; uint32 id -> (list hotkey thunk ref)
(define by-hotkey (make-hash)) ; (list mods key) -> id
(define next-id 1)
(define handler-ref (box #f)) ; keep FFI objects alive
(define pump-box (box #f))

(define (hk-key hk)
  (list (hotkey-mods hk) (hotkey-key hk)))

(define (lookup-thunk id)
  (call-with-semaphore sema
                       (lambda ()
                         (define entry (hash-ref by-id id #f))
                         (and entry (second entry)))))

;; The installed handler is the single dispatch point.
(define handler-cptr
  (and hitoolbox
       (function-ptr (lambda (call-ref event user-data)
                       (define out (make-EventHotKeyID 0 0))
                       (define status
                         (GetEventParameter event
                                            kEventParamDirectObject
                                            typeEventHotKeyID
                                            #f
                                            (ctype-sizeof _EventHotKeyID)
                                            #f
                                            out))
                       (when (= status noErr)
                         (define thunk (lookup-thunk (EventHotKeyID-id out)))
                         (when thunk
                           (thunk)))
                       noErr)
                     (_fun _pointer _pointer _pointer -> _int32))))

(define (log fmt . args)
  (apply fprintf (current-error-port) (string-append "[glaze-hotkey-macos] " fmt "\n") args))

(define (ensure-manager!)
  (call-with-semaphore
   sema
   (lambda ()
     (or (unbox pump-box)
         (let ()
           (define target (GetApplicationEventTarget))
           (define handler-out (box #f))
           (define status
             (InstallEventHandler target
                                  handler-cptr
                                  1
                                  (make-EventTypeSpec kEventClassKeyboard kEventHotKeyPressed)
                                  #f
                                  handler-out))
           (unless (= status noErr)
             (log "InstallEventHandler status ~a" status))
           (set-box! handler-ref (unbox handler-out))
           (define pump
             (thread (lambda ()
                       (define spec (make-EventTypeSpec kEventClassKeyboard kEventHotKeyPressed))
                       (let loop ()
                         (define-values (status ev) (ReceiveNextEvent 1 spec 0.05 #t))
                         (when (and (= status noErr) ev)
                           (SendEventToEventTarget ev target)
                           (ReleaseEvent ev))
                         (sleep 0.01)
                         (loop)))))
           (define st (vector status pump))
           (set-box! pump-box st)
           st)))))

(define (supported?)
  (and (eq? (system-type 'os) 'macosx)
       RegisterEventHotKey
       UnregisterEventHotKey
       InstallEventHandler
       ReceiveNextEvent
       #t))

(define (register! hk thunk)
  (and (supported?)
       (let ()
         (define st (ensure-manager!))
         (and (= (vector-ref st 0) noErr)
              (call-with-semaphore
               sema
               (lambda ()
                 (define k (hk-key hk))
                 (cond
                   [(hash-ref by-hotkey k #f) #f]
                   [else
                    (define id next-id)
                    (define code (hash-ref vk-table (hotkey-key hk) #f))
                    (and code
                         (let ()
                           (define-values (status ref)
                             (RegisterEventHotKey code
                                                  (mods->flags (hotkey-mods hk))
                                                  (make-EventHotKeyID hotkey-signature id)
                                                  0
                                                  (GetApplicationEventTarget)))
                           (and (= status noErr)
                                (begin
                                  (set! next-id (add1 id))
                                  (hash-set! by-id id (list hk thunk ref))
                                  (hash-set! by-hotkey k id)
                                  #t))))])))))))

(define (unregister! hk)
  (and (supported?)
       (call-with-semaphore sema
                            (lambda ()
                              (define id (hash-ref by-hotkey (hk-key hk) #f))
                              (and id
                                   (let ()
                                     (define entry (hash-ref by-id id))
                                     (hash-remove! by-id id)
                                     (hash-remove! by-hotkey (hk-key hk))
                                     (= (UnregisterEventHotKey (third entry)) noErr)))))))

(define (unregister-all!)
  (and (supported?)
       (call-with-semaphore sema
                            (lambda ()
                              (for ([entry (in-list (hash-values by-id))])
                                (UnregisterEventHotKey (third entry)))
                              (hash-clear! by-id)
                              (hash-clear! by-hotkey)
                              #t))))

(define (registered? hk)
  (call-with-semaphore sema (lambda () (and (hash-ref by-hotkey (hk-key hk) #f) #t))))
