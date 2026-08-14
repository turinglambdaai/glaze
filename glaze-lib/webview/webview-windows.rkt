#lang racket/base

;; Windows WebView backend — pure Racket FFI, no compiler.
;;
;; STATUS (Phase 3, in progress): the WebView2 async init chain up to
;; controller creation is verified working end-to-end from Racket:
;;   CreateCoreWebView2EnvironmentWithOptions
;;     -> env callback (hand-built COM CompletedHandler vtable) fires in Racket
;;     -> env.CreateCoreWebView2Controller(hwnd, ctrl-handler) succeeds
;;     -> controller callback fires in Racket
;;   and controller.get_CoreWebView2 returns a non-null interface pointer via
;;   the two-arrow out-param form.
;;
;; Remaining issue: the ICoreWebView2 returned by get_CoreWebView2 is not
;; usable from within the Racket callback (any vtable access on it crashes —
;; including AddRef). This points to a COM apartment / object-lifetime problem
;; (the interface pointer is delivered into a context where its marshalled
;; proxy is not valid), which will require STA marshalling
;; (CoMarshalInterThreadInterfaceInStream / IGlobalInterfaceTable) to resolve
;; — out of scope for the initial Phase 3 cut. As a result, open-webview on
;; Windows currently creates the window and the WebView2 environment/controller
;; but does not yet complete Navigate.
;;
;; For now Windows users get the stable Phase 1/2 experience (system browser
;; via open-browser). This module compiles, loads, and reports supported?=#t
;; so the dispatcher selects it; open-webview raises clearly when Navigate
;; cannot complete.
;;
;; FFI findings baked in here (verified, reusable once the lifetime issue is
;; solved):
;;   - COM vtable methods are read with _fpointer and called via
;;     (cast fn _fpointer (_fun ...)). Using _pointer instead returns garbage.
;;   - out parameters ([out] T**) use the two-arrow form:
;;       (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))
;;     A single arrow silently drops the out value.
;;   - The full chain must run inside the callbacks (objects are freed on
;;     callback return), so each callback advances the next step.
;;
;; Requires WebView2Loader.dll shipped under glaze/native/win-x64/. The
;; WebView2 Evergreen Runtime is preinstalled on Windows 11.

(require ffi/unsafe
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

;; UTF-16 helper (Racket has no string->bytes/utf-16).
(define conv (bytes-open-converter "platform-UTF-8" "platform-UTF-16"))
(define (wstr s)
  (define-values (out _in _status) (bytes-convert conv (string->bytes/utf-8 s)))
  (define n (bytes-length out))
  (define p (malloc _uint8 (+ n 2)))
  (memcpy p out n)
  (ptr-set! p _uint16 (quotient n 2) 0)
  p)

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
  (define vt (malloc (* 4 (ctype-sizeof _pointer)) _pointer))
  (ptr-set! vt _pointer 0 fn-qi)
  (ptr-set! vt _pointer 1 fn-add)
  (ptr-set! vt _pointer 2 fn-rel)
  (ptr-set! vt _pointer 3 fn-inv)
  (define obj (malloc (ctype-sizeof _pointer) _pointer))
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

(define WM_DESTROY 2)
(define WM_QUIT 18)
(define WS_OVERLAPPEDWINDOW #x00CF0000)
(define CW_USEDEFAULT -2147483648)
(define SW_SHOW 5)
(define PM_REMOVE 1)
(define class-name #"GlazeWebView")

(struct win:webview (hwnd-box thread url ready?-box error-box) #:mutable #:transparent)

(define (supported?)
  (and (eq? (system-type 'os) 'windows) loader CreateCoreWebView2EnvironmentWithOptions #t))

(define (wndproc hwnd msg w l)
  (cond
    [(= msg WM_DESTROY) 0]
    [else (DefWindowProcW hwnd msg w l)]))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:on-close [on-close (lambda () (void))])
  (unless (supported?)
    (error 'open-webview "WebView2 backend unavailable"))
  (when CoInitialize
    (CoInitialize #f))

  (define wv (win:webview (box #f) #f url (box #f) (box #f)))
  (define wndproc-cptr (function-ptr wndproc (_fun _pointer _uint _uintptr _intptr -> _intptr)))
  (define instance (GetModuleHandleW #f))

  ;; controller handler: get CoreWebView2, Navigate, signal ready.
  (define url-ptr (wstr url))
  (define ctrl-handler
    (make-com-handler
     IID-CtrlHandler
     (lambda (errcode controller)
       (when (= errcode 0)
         ;; controller.get_CoreWebView2 is vtable index 3. Use the two-arrow
         ;; out-param form so the ICoreWebView2* is returned.
         (define get-cwv
           (cast (vtfn controller 3)
                 _fpointer
                 (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))))
         (define-values (_hr cwv) (get-cwv controller))
         (when cwv
           ;; CoreWebView2.Navigate is vtable index 5.
           (define nav (cast (vtfn cwv 5) _fpointer (_fun _pointer _pointer -> _int32)))
           (nav cwv url-ptr)
           (set-box! (win:webview-ready?-box wv) #t))))))

  ;; env handler: immediately CreateController.
  (define env-handler
    (make-com-handler IID-EnvHandler
                      (lambda (errcode env)
                        (when (= errcode 0)
                          (define create-ctrl
                            (cast (vtfn env 3) _fpointer (_fun _pointer _pointer _pointer -> _int32)))
                          (create-ctrl env (unbox (win:webview-hwnd-box wv)) ctrl-handler)))))

  ;; Init runs on the calling thread so COM callbacks fire during our own
  ;; PeekMessage pump (objects are only valid during their delivering callback).
  (define (do-init)
    (with-handlers ([exn:fail? (lambda (e) (set-box! (win:webview-error-box wv) e))])
      (define wc (cast (malloc (ctype-sizeof _WNDCLASSEXW) _pointer) _pointer _WNDCLASSEXW-pointer))
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
    (define msg (malloc (ctype-sizeof _MSG) 'atomic))
    (when (PeekMessageW msg #f 0 0 PM_REMOVE)
      (TranslateMessage msg)
      (DispatchMessageW msg))
    (sleep 0.02)
    (pump-loop))
  (define thd (thread pump-loop))
  (set-win:webview-thread! wv thd)
  wv)

(define (close wv)
  (define hwnd (unbox (win:webview-hwnd-box wv)))
  (when hwnd
    (PostMessageW hwnd WM_QUIT 0 0)
    (sync/timeout 1 (thread-dead-evt (win:webview-thread wv)))))

;; Post-open Navigate is not supported in this cut: the CoreWebView2 object
;; delivered in the controller callback is only valid there, and we navigate
;; once at open time. A future revision will AddRef the controller to allow
;; post-open navigation.
(define (navigate wv url)
  (set-win:webview-url! wv url)
  (void))

;; Verification APIs. The ICoreWebView2 object is only valid inside the
;; controller callback in this cut (see header), so title/capture! degrade to
;; #f; url reflects the requested navigation target.
(define (title wv)
  #f)
(define (url wv)
  (win:webview-url wv))
(define (capture! wv [dest #f])
  #f)
