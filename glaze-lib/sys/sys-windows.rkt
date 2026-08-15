#lang racket/base

;; Windows system-integration backend. Clipboard via Win32 FFI;
;; open/reveal via explorer subprocesses. Notifications need either a
;; tray icon (Shell_NotifyIcon balloon) or WinRT toast COM — return #f
;; until the tray-based path is wired (documented limitation).

(require ffi/unsafe
         racket/system)

(provide supported?
         clipboard-set!
         clipboard-get
         notify!
         open-path
         reveal-path)

(define user32 (ffi-lib "user32"))
(define kernel32 (ffi-lib "kernel32"))

(define OpenClipboard (get-ffi-obj "OpenClipboard" user32 (_fun _pointer -> _bool)))
(define CloseClipboard (get-ffi-obj "CloseClipboard" user32 (_fun -> _bool)))
(define EmptyClipboard (get-ffi-obj "EmptyClipboard" user32 (_fun -> _bool)))
(define GetClipboardData
  (get-ffi-obj "GetClipboardData" user32 (_fun _uintptr -> _pointer)))
(define SetClipboardData
  (get-ffi-obj "SetClipboardData" user32 (_fun _uintptr _pointer -> _pointer)))
(define GlobalAlloc
  (get-ffi-obj "GlobalAlloc" kernel32 (_fun _uint _uintptr -> _pointer)))
(define GlobalLock
  (get-ffi-obj "GlobalLock" kernel32 (_fun _pointer -> _pointer)))
(define GlobalUnlock
  (get-ffi-obj "GlobalUnlock" kernel32 (_fun _pointer -> _bool)))
(define GlobalSize
  (get-ffi-obj "GlobalSize" kernel32 (_fun _pointer -> _uintptr)))

(define CF_UNICODETEXT 13)
(define GMEM_MOVEABLE 2)

;; UTF-16 helpers (bytes-open-converter is one-directional).
(define conv (bytes-open-converter "platform-UTF-8" "platform-UTF-16"))
(define (wstr s)
  (define-values (out _in _status) (bytes-convert conv (string->bytes/utf-8 s)))
  (define n (bytes-length out))
  (define p (malloc _uint8 (+ n 2) 'raw))
  (memcpy p out n)
  (ptr-set! p _uint16 (quotient n 2) 0)
  p)
(define (wstr->string p)
  (and p
       (let loop ([i 0] [chars '()])
         (define u (ptr-ref p _uint16 i))
         (if (zero? u)
             (list->string (reverse chars))
             (loop (add1 i) (cons (integer->char u) chars))))))

(define (supported?)
  (and (eq? (system-type 'os) 'windows) #t))

(define (clipboard-set! text)
  (and (OpenClipboard #f)
       (dynamic-wind
         (lambda () (void))
         (lambda ()
           (EmptyClipboard)
           (define p (wstr text))
           (define bytes-n (+ 2 (* 2 (length (string->list text)))))
           (define h (GlobalAlloc GMEM_MOVEABLE bytes-n))
           (define dst (GlobalLock h))
           (memcpy dst p bytes-n)
           (GlobalUnlock h)
           (not (zero? (cast (SetClipboardData CF_UNICODETEXT h) _pointer _intptr))))
         (lambda () (CloseClipboard)))))

(define (clipboard-get)
  (cond
    [(not (OpenClipboard #f)) ""]
    [else
     (dynamic-wind
       (lambda () (void))
       (lambda ()
         (define h (GetClipboardData CF_UNICODETEXT))
         (if (not h)
             ""
             (let ()
               (define p (GlobalLock h))
               (define s (wstr->string p))
               (GlobalUnlock h)
               (or s ""))))
       (lambda () (CloseClipboard)))]))

(define (notify! title body subtitle)
  ;; Requires a tray icon (balloon) or WinRT toast — not wired yet.
  #f)

(define (open-path p)
  (define e (find-executable-path "explorer.exe"))
  (and e (system* e p)))

(define (reveal-path p)
  (define e (find-executable-path "explorer.exe"))
  (and e (system* e "/select," p)))
