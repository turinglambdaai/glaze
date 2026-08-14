#lang racket/base

;; Windows tray backend using pure Racket FFI (no compiler required).
;;
;; Strategy:
;;   - Register a hidden message-only window (HWND_MESSAGE) with a custom
;;     WindowProc that receives the tray callback message.
;;   - Shell_NotifyIconW with NIM_ADD places the icon; the callback message is
;;     WM_USER and carries mouse events as lParam.
;;   - On right-button-up, build an HMENU from the menu items, TrackPopupMenu,
;;     and dispatch the chosen id back to its Racket action via an
;;     id-allocator.
;;   - A dedicated thread runs a GetMessage loop so the tray stays responsive
;;     without blocking the Racket main thread. The WindowProc runs on that
;;     same message-loop thread (Win32 requirement: the thread that created
;;     the window must pump its messages).
;;
;; All native resources (window, icon) are torn down on close.

(require ffi/unsafe
         ffi/winapi
         racket/path
         "tray-protocol.rkt")

;; Racket has no built-in string->bytes/utf-16; encode via the platform
;; converter. On Windows "platform-UTF-16" yields UTF-16LE. Falls back to
;; manual BMP encoding if the converter is unavailable.
(define utf16-converter (bytes-open-converter "platform-UTF-8" "platform-UTF-16"))

(define (string->utf16-bytes s [add-nul? #t])
  (define src (string->bytes/utf-8 s))
  (define-values (out _in _status)
    (if utf16-converter
        (bytes-convert utf16-converter src)
        (values (manual-utf16le s) (bytes-length src) 'complete)))
  (if add-nul?
      (bytes-append out #"\0\0")
      out))

;; Manual UTF-16LE encoder for BMP code points (converter-unavailable fallback).
(define (manual-utf16le s)
  (apply bytes-append
         (for/list ([ch (in-string s)])
           (define cp (char->integer ch))
           (bytes (bitwise-and cp #xff) (arithmetic-shift cp -8)))))

(provide make-tray
         set-tooltip!
         set-icon!
         set-menu!
         close
         supported?
         win:tray?
         win:tray-state)

;; ---- Win32 constants ----
(define TRAY_CALLBACK_MSG 1024) ; WM_USER
(define WM_DESTROY 2)
(define WM_COMMAND 273)
(define WM_RBUTTONUP 517)
(define WM_LBUTTONUP 514)
(define WM_QUIT 18)
(define PM_REMOVE 1)
(define HWND_MESSAGE -3)
(define WS_EX_TOOLWINDOW 128)
(define IMAGE_ICON 1)
(define LR_LOADFROMFILE 16)
(define NIM_ADD 0)
(define NIM_MODIFY 1)
(define NIM_DELETE 2)
(define NIF_MESSAGE 1)
(define NIF_ICON 2)
(define NIF_TIP 4)
(define MF_STRING 0)
(define MF_SEPARATOR 2048)
(define TPM_RIGHTALIGN 8)
(define TPM_BOTTOMALIGN 32)
(define TPM_RETURNCMD 256)
(define TPM_NONOTIFY 128)
(define NOTIFYICONDATAW-SIZE 104) ; sizeof on 64-bit per Win32 headers

;; ---- FFI libraries ----
(define user32 (ffi-lib "user32"))
(define shell32 (ffi-lib "shell32"))
(define kernel32 (ffi-lib "kernel32"))

(define (get-proc lib name type)
  (get-ffi-obj name lib type (lambda () #f)))

;; ---- FFI bindings ----
(define DefWindowProcW
  (get-proc user32 "DefWindowProcW" (_fun _pointer _uint _uintptr _intptr -> _intptr)))
(define RegisterClassExW (get-proc user32 "RegisterClassExW" (_fun _pointer -> _ushort)))
(define CreateWindowExW
  (get-proc user32
            "CreateWindowExW"
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
                  _pointer)))
(define DestroyWindow (get-proc user32 "DestroyWindow" (_fun _pointer -> _bool)))
(define PostMessageW (get-proc user32 "PostMessageW" (_fun _pointer _uint _uintptr _intptr -> _bool)))
(define PostQuitMessage (get-proc user32 "PostQuitMessage" (_fun _int -> _void)))
(define GetMessageW
  ;; #:blocking? #t tells the Racket scheduler this call may block in the OS,
  ;; so it can run other Racket threads instead of stalling the whole runtime.
  (get-proc user32 "GetMessageW" (_fun #:blocking? #t _pointer _pointer _uint _uint -> _int)))
(define TranslateMessage (get-proc user32 "TranslateMessage" (_fun _pointer -> _bool)))
(define DispatchMessageW (get-proc user32 "DispatchMessageW" (_fun _pointer -> _intptr)))
(define PeekMessageW
  (get-proc user32 "PeekMessageW" (_fun _pointer _pointer _uint _uint _uint -> _bool)))
(define GetCursorPos (get-proc user32 "GetCursorPos" (_fun _pointer -> _bool)))
(define SetForegroundWindow (get-proc user32 "SetForegroundWindow" (_fun _pointer -> _bool)))
(define CreatePopupMenu (get-proc user32 "CreatePopupMenu" (_fun -> _pointer)))
(define AppendMenuW (get-proc user32 "AppendMenuW" (_fun _pointer _uint _uintptr _pointer -> _bool)))
(define TrackPopupMenu
  (get-proc user32 "TrackPopupMenu" (_fun _pointer _uint _int _int _int _pointer _pointer -> _int)))
(define DestroyMenu (get-proc user32 "DestroyMenu" (_fun _pointer -> _bool)))
(define LoadImageW
  (get-proc user32 "LoadImageW" (_fun _pointer _pointer _uint _int _int _uint -> _pointer)))
(define Shell_NotifyIconW (get-proc shell32 "Shell_NotifyIconW" (_fun _uint _pointer -> _bool)))
(define GetModuleHandleW (get-proc kernel32 "GetModuleHandleW" (_fun _pointer -> _pointer)))

;; ---- C structs ----
(define-cstruct _POINT ([x _long] [y _long]))
(define-cstruct
 _MSG
 ([hwnd _pointer] [message _uint] [wParam _uintptr] [lParam _intptr] [time _uint] [pt _POINT]))

;; NOTIFYICONDATAW. We model only the fields we use plus enough tail to reach
;; the documented cbSize; Windows checks cbSize, not field semantics beyond
;; what uFlags requests.
(define-cstruct _NOTIFYICONDATAW
                ([cbSize _uint] [hWnd _pointer]
                                [uID _uint]
                                [uFlags _uint]
                                [uCallbackMessage _uint]
                                [hIcon _pointer]
                                ;; szTip is WCHAR[128] = 256 bytes; we expose it as a byte array.
                                [szTip (_array _uint8 256)]
                                ;; Tail covers dwState/dwStateMask/szInfo/guidItem/... so the struct's
                                ;; ctype-sizeof matches NOTIFYICONDATAW-SIZE on x64.
                                [_tail (_array _uint8 16)]))

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

;; Allocate a zeroed cstruct instance and return it as a pointer tagged with
;; `ptr-type` (the `<name>-pointer` type generated by define-cstruct). Tagged
;; pointers are what the generated setters accept.
(define (calloc-typed type ptr-type)
  (define raw (malloc (ctype-sizeof type)))
  (memset raw 0 (ctype-sizeof type))
  (cast raw _pointer ptr-type))

;; Registry: hWnd -> tray-state, so the WindowProc (which only receives hWnd)
;; can find the Racket-side state. The WindowProc cpointer is also retained
;; here so GC never reclaims it (a reclaimed callback pointer = crash).
(struct tray-state (hwnd icon-h allocator open?-box menu-box wndproc-cptr thread)
  #:mutable
  #:transparent)

(define registry (make-hash))
(define registry-sema (make-semaphore 1))

(define (registry-put! hwnd st)
  (call-with-semaphore registry-sema (lambda () (hash-set! registry hwnd st))))
(define (registry-ref hwnd)
  (call-with-semaphore registry-sema (lambda () (hash-ref registry hwnd #f))))
(define (registry-remove! hwnd)
  (call-with-semaphore registry-sema (lambda () (hash-remove! registry hwnd))))

;; Win32 handle wrapped with the backend tag is what the public API carries.
(struct win:tray (state) #:transparent)

(define (supported?)
  (and (eq? (system-type 'os) 'windows) #t))

;; ---- WindowProc ----
;; Module-level procedure (so it has a stable identity we can turn into a
;; cpointer once and keep alive in the registry).
(define (tray-wndproc hwnd msg wparam lparam)
  (define st (registry-ref hwnd))
  (cond
    [(not st) (DefWindowProcW hwnd msg wparam lparam)]
    [(= msg TRAY_CALLBACK_MSG)
     (cond
       [(= lparam WM_RBUTTONUP)
        (handle-context-menu st)
        0]
       [(= lparam WM_LBUTTONUP) 0]
       [else (DefWindowProcW hwnd msg wparam lparam)])]
    [(= msg WM_COMMAND)
     (define menu-id (bitwise-and wparam #xFFFF))
     (handle-menu-id st menu-id)
     0]
    [(= msg WM_DESTROY)
     (PostQuitMessage 0)
     0]
    [else (DefWindowProcW hwnd msg wparam lparam)]))

(define (handle-context-menu st)
  (define items (unbox (tray-state-menu-box st)))
  (define hmenu (CreatePopupMenu))
  (define alloc (tray-state-allocator st))
  (id-allocator-clear! alloc)
  (for ([mi (in-list items)])
    (cond
      [(menu-separator? mi) (AppendMenuW hmenu MF_SEPARATOR 0 #f)]
      [else
       (define mid (id-allocator-register! alloc (menu-item-action mi)))
       (AppendMenuW hmenu MF_STRING mid (string->utf16-ptr (or (menu-item-label mi) "")))]))
  (define-values (cx cy)
    (let ([pt (malloc _POINT 'atomic)])
      (GetCursorPos pt)
      (values (ptr-ref pt _long 0) (ptr-ref pt _long 1))))
  (SetForegroundWindow (tray-state-hwnd st))
  (define chosen
    (TrackPopupMenu hmenu
                    (+ TPM_RIGHTALIGN TPM_BOTTOMALIGN TPM_RETURNCMD TPM_NONOTIFY)
                    cx
                    cy
                    0
                    (tray-state-hwnd st)
                    #f))
  (DestroyMenu hmenu)
  (when (> chosen 0)
    (handle-menu-id st chosen)))

(define (handle-menu-id st menu-id)
  (define proc (id-allocator-lookup (tray-state-allocator st) menu-id))
  (when (procedure? proc)
    (proc)))

;; Convert a Racket string to a UTF-16LE byte pointer (NUL-terminated).
(define (string->utf16-ptr s)
  (define bs (string->utf16-bytes s #t))
  (define p (malloc _uint8 (bytes-length bs)))
  (memcpy p bs (bytes-length bs))
  p)

;; Write a UTF-16LE string into a NOTIFYICONDATAW.szTip array, capping at the
;; last WCHAR slot to leave room for the terminator.
(define (write-tip! nid tip-str)
  (define arr (NOTIFYICONDATAW-szTip nid))
  ;; Clear the array first so previous tips don't leak.
  (for ([i (in-range 256)])
    (array-set! arr i 0))
  (when (string? tip-str)
    (define tip-bs (string->utf16-bytes tip-str #f))
    (for ([b (in-bytes tip-bs)]
          [i (in-range 0 (min (bytes-length tip-bs) 254))])
      (array-set! arr i b))))

;; ---- Public backend API ----
(define (make-tray #:icon icon-path
                   #:tooltip tooltip
                   #:menu items
                   #:on-event [on-event (lambda (e) (void))])
  (unless (supported?)
    (error 'make-tray "Windows tray backend not available on this platform"))

  (define ready-ch (make-channel))
  ;; The state is created on the main thread, but hwnd/thread are filled in on
  ;; the worker thread below.
  (define st
    (tray-state #f ; hwnd
                #f ; icon-h
                (make-id-allocator)
                (box #t) ; open?-box
                items ; menu-box (mutable slot)
                #f ; wndproc-cptr
                #f)) ; thread
  (set-tray-state-menu-box! st items)

  ;; WindowProc closure + its cpointer, retained for the tray's lifetime.
  ;; function-ptr wraps a Racket procedure into a C-callable function pointer;
  ;; it MUST be kept alive (stored on the tray-state) or the GC will reclaim
  ;; it and the next window message will jump into freed memory.
  (define wndproc-type (_fun _pointer _uint _uintptr _intptr -> _intptr))
  (define wndproc-cptr (function-ptr tray-wndproc wndproc-type))
  (set-tray-state-wndproc-cptr! st wndproc-cptr)

  (define instance (GetModuleHandleW #f))
  (define class-name-ptr (string->utf16-ptr "GlazeTrayWindowClass"))

  (define (thunk)
    (with-handlers ([exn:fail? (lambda (e)
                                 ;; Worker died before signaling readiness: surface the
                                 ;; error on the main thread instead of hanging forever.
                                 (channel-put ready-ch (cons 'error e)))])
      ;; Register window class (idempotent across trays in the same process).
      (define wc (calloc-typed _WNDCLASSEXW _WNDCLASSEXW-pointer))
      (set-WNDCLASSEXW-cbSize! wc (ctype-sizeof _WNDCLASSEXW))
      (set-WNDCLASSEXW-lpfnWndProc! wc wndproc-cptr)
      (set-WNDCLASSEXW-hInstance! wc instance)
      (set-WNDCLASSEXW-lpszClassName! wc class-name-ptr)
      (RegisterClassExW wc)

      ;; Message-only hidden window.
      (define hwnd
        (CreateWindowExW WS_EX_TOOLWINDOW
                         class-name-ptr
                         (string->utf16-ptr "Glaze")
                         0
                         0
                         0
                         0
                         0
                         HWND_MESSAGE
                         #f
                         instance
                         #f))
      (unless hwnd
        (error 'make-tray "CreateWindowExW returned NULL"))
      (set-tray-state-hwnd! st hwnd)
      (registry-put! hwnd st)

      ;; Load icon (optional).
      (define icon-h
        (and
         icon-path
         (file-exists? icon-path)
         (LoadImageW #f (string->utf16-ptr (path->string icon-path)) IMAGE_ICON 0 0 LR_LOADFROMFILE)))
      (set-tray-state-icon-h! st icon-h)

      ;; Add the notify icon.
      (define nid (calloc-typed _NOTIFYICONDATAW _NOTIFYICONDATAW-pointer))
      (set-NOTIFYICONDATAW-cbSize! nid (ctype-sizeof _NOTIFYICONDATAW))
      (set-NOTIFYICONDATAW-hWnd! nid hwnd)
      (set-NOTIFYICONDATAW-uID! nid 1)
      (set-NOTIFYICONDATAW-uFlags! nid (bitwise-ior NIF_MESSAGE NIF_ICON NIF_TIP))
      (set-NOTIFYICONDATAW-uCallbackMessage! nid TRAY_CALLBACK_MSG)
      (set-NOTIFYICONDATAW-hIcon! nid icon-h)
      (write-tip! nid tooltip)
      (define added (Shell_NotifyIconW NIM_ADD nid))
      (unless added
        (error 'make-tray "Shell_NotifyIconW NIM_ADD failed"))

      ;; Signal readiness, then pump messages until WM_QUIT. We POLL with
      ;; PeekMessageW instead of blocking on GetMessageW because a blocking
      ;; GetMessageW stalls the whole Racket scheduler (Racket's cooperative
      ;; threads share one OS thread and don't preempt inside foreign calls,
      ;; and #:blocking? turned out insufficient in practice here). Polling
      ;; with a short Racket-side sleep keeps the tray responsive AND lets the
      ;; rest of the app run.
      (channel-put ready-ch #t)
      (let loop ()
        (define msg (malloc _MSG 'atomic))
        (define got? (PeekMessageW msg #f 0 0 PM_REMOVE))
        (cond
          [got?
           (TranslateMessage msg)
           (DispatchMessageW msg)
           ;; WM_QUIT arrives via PostMessageW in close(); a peeked WM_QUIT
           ;; means we're done.
           (unless (= (MSG-message msg) WM_QUIT)
             (loop))]
          [else
           (sleep 0.02)
           (loop)]))

      ;; Cleanup on the loop thread.
      (define nid-del (calloc-typed _NOTIFYICONDATAW _NOTIFYICONDATAW-pointer))
      (set-NOTIFYICONDATAW-cbSize! nid-del (ctype-sizeof _NOTIFYICONDATAW))
      (set-NOTIFYICONDATAW-hWnd! nid-del hwnd)
      (set-NOTIFYICONDATAW-uID! nid-del 1)
      (Shell_NotifyIconW NIM_DELETE nid-del)
      (when hwnd
        (DestroyWindow hwnd))))

  (define thd (thread thunk))
  (set-tray-state-thread! st thd)
  ;; Wait for window creation so callers can immediately use the handle.
  (define ready (channel-get ready-ch))
  (when (and (pair? ready) (eq? (car ready) 'error))
    (raise (cdr ready)))
  (win:tray st))

(define (set-tooltip! t tooltip)
  (define st (win:tray-state t))
  (define nid (make-nid-for st))
  (write-tip! nid tooltip)
  (Shell_NotifyIconW NIM_MODIFY nid))

(define (set-icon! t icon-path)
  (define st (win:tray-state t))
  (when (and icon-path (file-exists? icon-path))
    (define new-icon
      (LoadImageW #f (string->utf16-ptr (path->string icon-path)) IMAGE_ICON 0 0 LR_LOADFROMFILE))
    (set-tray-state-icon-h! st new-icon)
    (define nid (make-nid-for st))
    (Shell_NotifyIconW NIM_MODIFY nid)))

(define (set-menu! t items)
  (set-tray-state-menu-box! (win:tray-state t) items))

(define (close t)
  (define st (win:tray-state t))
  (define hwnd (tray-state-hwnd st))
  (when hwnd
    (PostMessageW hwnd WM_QUIT 0 0)
    (sync/timeout 1 (thread-dead-evt (tray-state-thread st))))
  (when hwnd
    (registry-remove! hwnd)))

(define (make-nid-for st)
  (define nid (calloc-typed _NOTIFYICONDATAW _NOTIFYICONDATAW-pointer))
  (set-NOTIFYICONDATAW-cbSize! nid (ctype-sizeof _NOTIFYICONDATAW))
  (set-NOTIFYICONDATAW-hWnd! nid (tray-state-hwnd st))
  (set-NOTIFYICONDATAW-uID! nid 1)
  (set-NOTIFYICONDATAW-uFlags! nid (bitwise-ior NIF_MESSAGE NIF_ICON NIF_TIP))
  (set-NOTIFYICONDATAW-uCallbackMessage! nid TRAY_CALLBACK_MSG)
  (set-NOTIFYICONDATAW-hIcon! nid (tray-state-icon-h st))
  nid)
