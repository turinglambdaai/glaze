#lang racket/base

;; Windows WebView backend — pure Racket FFI, no compiler.
;;
;; STATUS (Phase 3): full pipeline — window, WebView2 environment,
;; controller, Navigate, post-open navigate/title/url, and window capture —
;; all against vtable indices verified against the official WebView2 SDK
;; header (Microsoft.Web.WebView2 nupkg, build/native/include/webview2.h).
;;
;; Vtable indices (IUnknown = 0..2):
;;   ICoreWebView2Environment : CreateCoreWebView2Controller = 3
;;   ICoreWebView2Controller  : get_CoreWebView2 = 25
;;   ICoreWebView2            : get_Source = 4, Navigate = 5,
;;                              get_DocumentTitle = 48, OpenDevToolsWindow = 51
;;
;; HISTORY / debugging note: for a long time this backend appeared blocked
;; on a "COM apartment / object lifetime" issue — the ICoreWebView2 obtained
;; from get_CoreWebView2 crashed on ANY vtable access, even AddRef. The real
;; cause was a wrong vtable index: calling slot 3 on the controller invokes
;; get_IsVisible, which writes a BOOL into the out-pointer; reading that
;; back as ICoreWebView2* yields 1 + heap garbage — a non-null pointer to
;; nothing. If you extend this file, verify every new vtable slot against
;; the SDK header, not against "neighboring" interfaces.
;;
;; Object lifetime: the controller and CoreWebView2 interfaces are AddRef'd
;; inside the controller callback and kept in the handle, so Navigate /
;; title / url work after the init callbacks complete. All calls stay on
;; the single Racket OS thread (the STA the environment was created on).
;;
;; FFI findings (verified, reusable):
;;   - COM vtable methods are read with _fpointer and called via
;;     (cast fn _fpointer (_fun ...)). Using _pointer instead returns garbage.
;;   - out parameters ([out] T**) use the two-arrow form:
;;       (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))
;;   - ALWAYS check the HRESULT before using the out value.
;;   - The async init chain must run inside the callbacks (each callback
;;     advances the next step); our PeekMessage pump on the same thread
;;     delivers them.
;;
;; Requires WebView2Loader.dll shipped under glaze/native/win-x64/. The
;; WebView2 Evergreen Runtime is preinstalled on Windows 11.

(require ffi/unsafe
         racket/file
         racket/string
         racket/system
         racket/runtime-path)

(provide open-webview
         supported?
         close
         navigate
         title
         url
         capture!
         win:webview?)

(define-runtime-path here ".")
(define loader-path (build-path here ".." "native" "win-x64" "WebView2Loader"))

(define user32 (ffi-lib "user32"))
(define kernel32 (ffi-lib "kernel32"))
(define ole32 (ffi-lib "ole32"))
(define gdi32 (ffi-lib "gdi32"))
(define loader
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib loader-path)))

(define S_OK 0)
(define E_NOINTERFACE #x80004002)
(define IID-IUnknown (bytes 0 0 0 0 0 0 0 0 #xC0 0 0 0 0 0 0 #x46))
;; ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
(define IID-EnvHandler
  (bytes #x89 #x33 #x8A #x4E #xC9 #xD8 #x42 #x32 #x9C #x0E #x9C #xCB #x5B #x9F #x79 #xF5))
;; ICoreWebView2CreateCoreWebView2ControllerCompletedHandler
(define IID-CtrlHandler
  (bytes #xE0 #xA7 #xC1 #x63 #x68 #xCB #x3B #x44 #x8B #xA8 #x4D #x08 #xCF #x11 #xF0 #xAE))

(define (log fmt . args)
  (apply fprintf (current-error-port) (string-append "[glaze-win-webview] " fmt "\n") args))

;; UTF-16 helper (Racket has no string->bytes/utf-16).
(define conv (bytes-open-converter "platform-UTF-8" "platform-UTF-16"))
(define (wstr s)
  (define-values (out _in _status) (bytes-convert conv (string->bytes/utf-8 s)))
  (define n (bytes-length out))
  (define p (malloc _uint8 (+ n 2) 'raw))
  (memcpy p out n)
  (ptr-set! p _uint16 (quotient n 2) 0)
  p)

;; NOTE: bytes-open-converter is one-directional; converting UTF-16 back
;; with a UTF-8->UTF-16 converter silently produces garbage ("E\0\0\0...").
;; Walk the UTF-16 units directly instead.
(define (wstr->string p)
  (and p
       (let loop ([i 0] [chars '()])
         (define u (ptr-ref p _uint16 i))
         (if (zero? u)
             (list->string (reverse chars))
             (loop (add1 i) (cons (integer->char u) chars))))))

(define (ptr->bytes p n)
  (define bs (make-bytes n))
  (memcpy bs p n)
  bs)

;; Read vtable[index] as a callable function pointer.
(define (vtfn obj index)
  (define vtable (ptr-ref obj _pointer))
  (ptr-ref (ptr-add vtable (* index (ctype-sizeof _pointer))) _fpointer))

;; ---- COM handler objects (hand-built vtable; function pointers kept alive) ----
(define handler-table (make-hasheq))
(define (make-com-handler iid on-invoke)
  (define (qi self in-iid out)
    (define incoming (ptr->bytes in-iid 16))
    (cond
      [(or (bytes=? incoming iid) (bytes=? incoming IID-IUnknown))
       (ptr-set! out _pointer 0 self)
       S_OK]
      [else
       (ptr-set! out _pointer 0 #f)
       E_NOINTERFACE]))
  (define (addref self)
    2)
  (define (release self)
    1)
  (define (invoke self errcode result)
    (on-invoke errcode result)
    S_OK)
  (define fn-qi (function-ptr qi (_fun _pointer _pointer _pointer -> _int32)))
  (define fn-add (function-ptr addref (_fun _pointer -> _uint32)))
  (define fn-rel (function-ptr release (_fun _pointer -> _uint32)))
  (define fn-inv (function-ptr invoke (_fun _pointer _int32 _pointer -> _int32)))
  (define vt (malloc (* 4 (ctype-sizeof _pointer)) _pointer 'raw))
  (ptr-set! vt _pointer 0 fn-qi)
  (ptr-set! vt _pointer 1 fn-add)
  (ptr-set! vt _pointer 2 fn-rel)
  (ptr-set! vt _pointer 3 fn-inv)
  (define obj (malloc (ctype-sizeof _pointer) _pointer 'raw))
  (ptr-set! obj _pointer 0 vt)
  (hash-set! handler-table obj (list fn-qi fn-add fn-rel fn-inv))
  obj)

;; ---- Win32 / WebView2 bindings ----
(define CreateCoreWebView2EnvironmentWithOptions
  (and loader
       (get-ffi-obj "CreateCoreWebView2EnvironmentWithOptions"
                    loader
                    (_fun _pointer _pointer _pointer _pointer -> _int32)
                    (lambda () #f))))
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
(define ShowWindow (get-ffi-obj "ShowWindow" user32 (_fun _pointer _int -> _bool) (lambda () #f)))
(define PeekMessageW
  (get-ffi-obj "PeekMessageW"
               user32
               (_fun _pointer _pointer _uint _uint _uint -> _bool)
               (lambda () #f)))
(define TranslateMessage
  (get-ffi-obj "TranslateMessage" user32 (_fun _pointer -> _bool) (lambda () #f)))
(define DispatchMessageW
  (get-ffi-obj "DispatchMessageW" user32 (_fun _pointer -> _intptr) (lambda () #f)))
(define PostMessageW
  (get-ffi-obj "PostMessageW" user32 (_fun _pointer _uint _uintptr _intptr -> _bool) (lambda () #f)))
(define GetModuleHandleW
  (get-ffi-obj "GetModuleHandleW" kernel32 (_fun _pointer -> _pointer) (lambda () #f)))
(define CoInitialize (get-ffi-obj "CoInitialize" ole32 (_fun _pointer -> _int32) (lambda () #f)))

;; ---- GDI capture bindings (capture! via PrintWindow) ----
(define GetClientRect
  (get-ffi-obj "GetClientRect" user32 (_fun _pointer _pointer -> _bool) (lambda () #f)))
(define GetDC (get-ffi-obj "GetDC" user32 (_fun _pointer -> _pointer) (lambda () #f)))
(define ReleaseDC
  (get-ffi-obj "ReleaseDC" user32 (_fun _pointer _pointer -> _int) (lambda () #f)))
(define CreateCompatibleDC
  (get-ffi-obj "CreateCompatibleDC" gdi32 (_fun _pointer -> _pointer) (lambda () #f)))
(define DeleteDC (get-ffi-obj "DeleteDC" gdi32 (_fun _pointer -> _bool) (lambda () #f)))
(define CreateCompatibleBitmap
  (get-ffi-obj "CreateCompatibleBitmap" gdi32 (_fun _pointer _int _int -> _pointer) (lambda () #f)))
(define SelectObject
  (get-ffi-obj "SelectObject" gdi32 (_fun _pointer _pointer -> _pointer) (lambda () #f)))
(define DeleteObject (get-ffi-obj "DeleteObject" gdi32 (_fun _pointer -> _bool) (lambda () #f)))
(define PrintWindow
  (get-ffi-obj "PrintWindow" user32 (_fun _pointer _pointer _uint -> _bool) (lambda () #f)))
(define GetDIBits
  (get-ffi-obj "GetDIBits"
               gdi32
               (_fun _pointer _pointer _uint _uint _pointer _pointer _uint -> _int)
               (lambda () #f)))

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
(define-cstruct _RECT ([left _long] [top _long] [right _long] [bottom _long]))
;; BITMAPINFOHEADER + BITMAPINFO for GetDIBits.
(define-cstruct _BMIH
                ([biSize _uint]
                 [biWidth _long]
                 [biHeight _long]
                 [biPlanes _ushort]
                 [biBitCount _ushort]
                 [biCompression _uint]
                 [biSizeImage _uint]
                 [biXPelsPerMeter _long]
                 [biYPelsPerMeter _long]
                 [biClrUsed _uint]
                 [biClrImportant _uint]))
(define-cstruct _BMI ([bmiHeader _BMIH] [bmiColors _uint32]))

(define WM_DESTROY 2)
(define WM_CLOSE 16)
(define WM_QUIT 18)
(define WS_OVERLAPPEDWINDOW #x00CF0000)
(define CW_USEDEFAULT -2147483648)
(define SW_SHOW 5)
(define PM_REMOVE 1)
(define PW_RENDERFULLCONTENT 2)
(define BI_RGB 0)
(define DIB_RGB_COLORS 0)
(define class-name #"GlazeWebView")

(struct win:webview (hwnd-box
                     [controller-box #:mutable]
                     [cwv-box #:mutable]
                     [url #:mutable]
                     ready?-box
                     error-box
                     closed?-box
                     [thread #:mutable]
                     on-close)
  #:transparent)

(define (supported?)
  (and (eq? (system-type 'os) 'windows) loader CreateCoreWebView2EnvironmentWithOptions #t))

;; WM_CLOSE from the title bar: forward to our close semantics.
(define wndprocs (make-hasheq)) ; hwnd-addr -> wv (for WM_CLOSE dispatch)
(define wndproc-cptr
  (function-ptr
   (lambda (hwnd msg w l)
     (cond
       [(= msg WM_CLOSE)
        (define wv (hash-ref wndprocs (cast hwnd _pointer _uintptr) #f))
        (cond
          [(and wv (not (unbox (win:webview-closed?-box wv))))
           (set-box! (win:webview-closed?-box wv) #t)
           ((win:webview-on-close wv))
           (DestroyWindow-maybe hwnd)]
          [else (DefWindowProcW hwnd msg w l)])]
       [(= msg WM_DESTROY) 0]
       [else (DefWindowProcW hwnd msg w l)]))
   (_fun _pointer _uint _uintptr _intptr -> _intptr)))

;; WM_CLOSE path needs DestroyWindow.
(define DestroyWindow
  (get-ffi-obj "DestroyWindow" user32 (_fun _pointer -> _bool) (lambda () #f)))
(define (DestroyWindow-maybe hwnd)
  (when DestroyWindow (DestroyWindow hwnd))
  0)

;; COM out-param call helpers: always surface the HRESULT.
(define (call-with-out obj idx)
  (define fn (cast (vtfn obj idx)
                   _fpointer
                   (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))))
  (fn obj))

(define (cwv-getter idx) ; LPCWSTR-returning getters (get_Source / get_DocumentTitle)
  (lambda (cwv)
    (and cwv
         (let ()
           (define fn (cast (vtfn cwv idx)
                            _fpointer
                            (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))))
           (define-values (hr p) (fn cwv))
           (and (= hr S_OK) (wstr->string p))))))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:devtools? [devtools? #f]
                      #:on-close [on-close (lambda () (void))])
  (unless (supported?)
    (error 'open-webview "WebView2 backend unavailable"))
  (when CoInitialize
    (CoInitialize #f))

  (define wv (win:webview (box #f) #f #f url (box #f) (box #f) (box #f) #f on-close))
  (define instance (GetModuleHandleW #f))

  ;; controller callback: AddRef both interfaces into the handle, Navigate,
  ;; signal ready.
  (define url-ptr (wstr url))
  (define ctrl-handler
    (make-com-handler
     IID-CtrlHandler
     (lambda (errcode controller)
       (if (not (= errcode 0))
           (begin (log "controller callback error 0x~x" (bitwise-and errcode #xffffffff))
                  (set-box! (win:webview-error-box wv)
                            (error 'open-webview "CreateController failed: 0x~x"
                                   (bitwise-and errcode #xffffffff))))
           (let ()
             ;; AddRef keeps them valid beyond the callback (same STA thread).
             (define addref (cast (vtfn controller 1) _fpointer (_fun _pointer -> _uint32)))
             (addref controller)
             (set-win:webview-controller-box! wv controller)
             (define-values (hr cwv) (call-with-out controller 25)) ; get_CoreWebView2
             (if (not (= hr S_OK))
                 (begin (log "get_CoreWebView2 failed 0x~x" (bitwise-and hr #xffffffff))
                        (set-box! (win:webview-error-box wv)
                                  (error 'open-webview "get_CoreWebView2 failed: 0x~x"
                                         (bitwise-and hr #xffffffff))))
                 (let ()
                   (addref cwv)
                   (set-win:webview-cwv-box! wv cwv)
                   ;; Size the WebView to the client area (put_Bounds = 6);
                   ;; without this the controller keeps default bounds.
                   (define rc (make-RECT 0 0 0 0))
                   (GetClientRect (unbox (win:webview-hwnd-box wv)) rc)
                   (define put-bounds
                     (cast (vtfn controller 6) _fpointer (_fun _pointer _RECT -> _int32)))
                   (put-bounds controller
                               (make-RECT 0 0 (RECT-right rc) (RECT-bottom rc)))
                   (define nav (cast (vtfn cwv 5) _fpointer (_fun _pointer _pointer -> _int32)))
                   (define nav-hr (nav cwv url-ptr))
                   (log "Navigate hr=0x~x" (bitwise-and nav-hr #xffffffff))
                   (when devtools?
                     (define od (cast (vtfn cwv 51) _fpointer (_fun _pointer -> _int32)))
                     (od cwv))
                   (set-box! (win:webview-ready?-box wv) #t))))))))

  ;; env handler: immediately CreateController.
  (define env-handler
    (make-com-handler IID-EnvHandler
                      (lambda (errcode env)
                        (if (not (= errcode 0))
                            (begin (log "environment callback error 0x~x"
                                        (bitwise-and errcode #xffffffff))
                                   (set-box! (win:webview-error-box wv)
                                             (error 'open-webview
                                                    "CreateEnvironment failed: 0x~x"
                                                    (bitwise-and errcode #xffffffff))))
                            (let ()
                              (define create-ctrl
                                (cast (vtfn env 3)
                                      _fpointer
                                      (_fun _pointer _pointer _pointer -> _int32)))
                              (create-ctrl env
                                           (unbox (win:webview-hwnd-box wv))
                                           ctrl-handler))))))

  ;; Init runs on the calling thread so COM callbacks fire during our own
  ;; PeekMessage pump.
  (define (do-init)
    (with-handlers ([exn:fail? (lambda (e) (set-box! (win:webview-error-box wv) e))])
      (define wc (cast (malloc (ctype-sizeof _WNDCLASSEXW) 'raw _pointer)
                       _pointer
                       _WNDCLASSEXW-pointer))
      (memset wc 0 (ctype-sizeof _WNDCLASSEXW))
      (set-WNDCLASSEXW-cbSize! wc (ctype-sizeof _WNDCLASSEXW))
      (set-WNDCLASSEXW-lpfnWndProc! wc wndproc-cptr)
      (set-WNDCLASSEXW-hInstance! wc instance)
      (set-WNDCLASSEXW-lpszClassName! wc class-name)
      (RegisterClassExW wc)

      (define hwnd
        (CreateWindowExW 0
                         class-name
                         (wstr title)
                         WS_OVERLAPPEDWINDOW
                         CW_USEDEFAULT
                         CW_USEDEFAULT
                         width
                         height
                         0
                         #f
                         instance
                         #f))
      (set-box! (win:webview-hwnd-box wv) hwnd)
      (hash-set! wndprocs (cast hwnd _pointer _uintptr) wv)
      (ShowWindow hwnd SW_SHOW)

      (define data-folder
        (wstr (path->string (build-path (find-system-path 'temp-dir) "glaze-webview2"))))
      (define hr (CreateCoreWebView2EnvironmentWithOptions #f data-folder #f env-handler))
      (unless (= (bitwise-and hr #xffffffff) 0)
        (error 'open-webview
               "CreateCoreWebView2Environment failed: 0x~x"
               (bitwise-and hr #xffffffff)))

      ;; Pump until the controller callback signals ready (or timeout).
      (let loop ([deadline (+ (current-inexact-milliseconds) 15000)])
        (unless (or (unbox (win:webview-ready?-box wv))
                    (unbox (win:webview-error-box wv))
                    (> (current-inexact-milliseconds) deadline))
          (define msg (malloc (ctype-sizeof _MSG) 'atomic))
          (when (PeekMessageW msg #f 0 0 PM_REMOVE)
            (TranslateMessage msg)
            (DispatchMessageW msg))
          (sleep 0.02)
          (loop deadline)))))

  (do-init)
  (when (unbox (win:webview-error-box wv))
    (raise (unbox (win:webview-error-box wv))))

  ;; Spawn a thread for the ongoing message pump.
  (define (pump-loop)
    (unless (unbox (win:webview-closed?-box wv))
      (define msg (malloc (ctype-sizeof _MSG) 'atomic))
      (when (PeekMessageW msg #f 0 0 PM_REMOVE)
        (TranslateMessage msg)
        (DispatchMessageW msg))
      (sleep 0.01)
      (pump-loop)))
  (set-win:webview-thread! wv (thread pump-loop))
  wv)

(define (close wv)
  (unless (unbox (win:webview-closed?-box wv))
    (set-box! (win:webview-closed?-box wv) #t)
    ((win:webview-on-close wv))
    (define hwnd (unbox (win:webview-hwnd-box wv)))
    (when hwnd
      (DestroyWindow-maybe hwnd)
      (PostMessageW hwnd WM_QUIT 0 0))
    (sync/timeout 1 (thread-dead-evt (win:webview-thread wv)))))

;; Post-open Navigate against the retained ICoreWebView2 (same STA thread).
(define (navigate wv url)
  (set-win:webview-url! wv url)
  (define cwv (win:webview-cwv-box wv))
  (when cwv
    (define nav (cast (vtfn cwv 5) _fpointer (_fun _pointer _pointer -> _int32)))
    (nav cwv (wstr url))))

;; Verification APIs: synchronous getters against the retained interface.
(define title
  (lambda (wv) ((cwv-getter 48) (win:webview-cwv-box wv)))) ; get_DocumentTitle
(define url
  (lambda (wv) ((cwv-getter 4) (win:webview-cwv-box wv)))) ; get_Source

;; Window capture: PrintWindow into a DIB, write a BMP, convert to PNG with
;; PowerShell's System.Drawing (present on every Windows install).
(define (capture! wv [dest #f])
  (with-handlers ([exn:fail? (lambda (e)
                               (log "capture failed: ~a" (exn-message e))
                               #f)])
  (and (not (unbox (win:webview-closed?-box wv)))
       GetClientRect
       PrintWindow
       (let ()
         (define hwnd (unbox (win:webview-hwnd-box wv)))
         (define rc (make-RECT 0 0 0 0))
         (GetClientRect hwnd rc)
         (define w (- (RECT-right rc) (RECT-left rc)))
         (define h (- (RECT-bottom rc) (RECT-top rc)))
         (and (> w 0)
              (> h 0)
              (let ()
                (define hdc (GetDC hwnd))
                (define mem (CreateCompatibleDC hdc))
                (define bmp (CreateCompatibleBitmap hdc w h))
                (define old (SelectObject mem bmp))
                (PrintWindow hwnd mem PW_RENDERFULLCONTENT)
                (define bmi (make-BMI
                             (make-BMIH (ctype-sizeof _BMIH)
                                        w
                                        (- h) ; top-down
                                        1
                                        32
                                        BI_RGB
                                        0 0 0 0 0)
                             0))
                (define buf (malloc (* 4 w h) _uint8 'raw))
                (define got (GetDIBits mem bmp 0 h buf bmi DIB_RGB_COLORS))
                (SelectObject mem old)
                (DeleteObject bmp)
                (DeleteDC mem)
                (ReleaseDC hwnd hdc)
                (and (> got 0)
                     (let ()
                       ;; BMP file: header + (padded) BGRA rows.
                       (define row (* 4 w))
                       (define data-size (* row h))
                       (define file-size (+ 54 data-size))
                       (define out (make-bytes file-size 0))
                       (bytes-copy! out 0 (bytes #x42 #x4D))
                       (integer->integer-bytes file-size 4 #f #t out 2)
                       (integer->integer-bytes 54 4 #f #t out 10)
                       (integer->integer-bytes 40 4 #f #t out 14)
                       (integer->integer-bytes w 4 #f #t out 18)
                       (integer->integer-bytes h 4 #f #t out 22)
                       (bytes-set! out 26 1)
                       (bytes-set! out 28 32)
                       (integer->integer-bytes data-size 4 #f #t out 34)
                       (memcpy (ptr-add out 54) buf data-size)
                       (define bmp-path
                         (make-temporary-file "glaze-capture-~a.bmp"))
                       (call-with-output-file bmp-path
                         (lambda (o) (write-bytes out o))
                         #:exists 'replace)
                       (define png-path
                         (if dest
                             (if (string? dest) (string->path dest) dest)
                             (make-temporary-file "glaze-capture-~a.png")))
                       (define ps
                         (string-append
                          "Add-Type -AssemblyName System.Drawing;"
                          "$b=[System.Drawing.Bitmap]::FromFile('"
                          (path->string bmp-path)
                          "');$b.Save('"
                          (path->string png-path)
                          "', [System.Drawing.Imaging.ImageFormat]::Png);$b.Dispose()"))
                       (define ok? (with-handlers ([exn:fail? (lambda (e) #f)])
                                     (parameterize ([current-directory (find-system-path 'temp-dir)])
                                       (system* (find-executable-path "powershell.exe")
                                                "-NoProfile" "-NonInteractive" "-Command" ps))))
                       (delete-file bmp-path)
                       (and ok? (file-exists? png-path) png-path)))))))))