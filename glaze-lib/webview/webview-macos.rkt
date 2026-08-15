#lang racket/base

;; macOS WebView backend using Racket's ffi/unsafe/objc (no compiler required).
;;
;; Creates an NSWindow containing a WKWebView and loads the given URL. The objc
;; FFI pattern is the same one used by the Phase 2 tray (NSStatusBar).
;;
;; STATUS (Phase 3): verified working end-to-end on macOS 26 (Sequoia,
;; Racket 9.2 arm64): window creation, page loads over local HTTP (both
;; 127.0.0.1 and localhost), webview-navigate, programmatic close, the red
;; close button, #:on-close delivery, and pump-thread shutdown.
;;
;; Design:
;;   - WebKit.framework is loaded explicitly via ffi-lib; objc_getClass does
;;     not auto-load frameworks, and while AppKit classes are resolvable from
;;     the plain racket process, WKWebView is not.
;;   - The NSApplication event loop cannot run via [NSApp run] (the blocking
;;     FFI call would stall every Racket thread), so a dedicated pump thread
;;     runs the main run loop with runMode:beforeDate: (the modal-loop idiom):
;;     it services AppKit's event source AND every other main-runloop source —
;;     WKWebView's XPC/IPC replies, NSTimers, GCD main-queue callbacks.
;;   - The pump sleeps briefly between iterations: when a runloop source is
;;     always ready, runMode returns immediately, and a yield-less loop would
;;     monopolize the OS thread and starve every other Racket thread.
;;   - Each pump iteration runs inside its own NSAutoreleasePool so transient
;;     ObjC objects are drained instead of accumulating for the process
;;     lifetime.
;;   - #:on-close is delivered through an NSWindow delegate: a singleton ObjC
;;     class implements windowWillClose: and dispatches to the Racket thunk
;;     registered under the closing window's pointer (same registry idea as
;;     the tray's tag-table).
;;   - The WKWebView is installed via setContentView: with
;;     autoresizingMask = width|height sizable so it tracks window resizes,
;;     and the window sets releasedWhenClosed:NO so our handle never dangles.
;;
;; FFI findings baked in here (verified, reusable):
;;   - CGFloat/NSRect fields require inexact values — Racket FFI rejects the
;;     exact integer 0 for _double (pass 0.0, (* 1.0 w)).
;;   - Struct-by-value arguments (NSRect/NSSize) must be passed with an
;;     explicit #:type annotation; untyped tell arguments are marshalled as
;;     _id and a struct cpointer fails id->C.
;;   - nextEventMatchingMask:untilDate:inMode:dequeue: does NOT service the
;;     runloop's other sources (verified: NSTimers never fire, WKWebView
;;     loads stall at estimatedProgress 0.1); runMode:beforeDate: does.

(require ffi/unsafe
         ffi/unsafe/objc
         racket/file)

(provide open-webview
         supported?
         close
         navigate
         title
         url
         capture!
         mac:webview?
         mac:webview-window
         mac:webview-webview
         mac:webview-thread)

;; WKWebView lives in WebKit.framework, which is not linked into the plain
;; racket process — load it once up front so import-class resolves.
(define webkit
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "/System/Library/Frameworks/WebKit.framework/WebKit")))

;; Window capture lives in CoreGraphics.
(define coregraphics
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")))

(import-class NSString
              NSApplication
              NSMenu
              NSMenuItem
              NSWindow
              NSView
              NSNotification
              NSObject
              NSAutoreleasePool
              NSDate
              NSRunLoop
              NSURL
              NSURLRequest
              NSBitmapImageRep
              WKWebView
              WKWebViewConfiguration)

;; AppKit geometry structs (CGRect family; ffi/unsafe/objc does not
;; predefine them, same as the tray backend defines _NSSize).
(define-cstruct _NSPoint ([x _double] [y _double]))
(define-cstruct _NSSize ([width _double] [height _double]))
(define-cstruct _NSRect ([origin _NSPoint] [size _NSSize]))

;; ---- window capture (CoreGraphics) ----
(define CGWindowListCreateImage
  (and coregraphics
       (get-ffi-obj "CGWindowListCreateImage"
                    coregraphics
                    (_fun _NSRect _uint _uint _uint -> _pointer)
                    (lambda () #f))))
(define CGImageRelease
  (and coregraphics
       (get-ffi-obj "CGImageRelease" coregraphics (_fun _pointer -> _void) (lambda () #f))))
(define kCGWindowListOptionIncludingWindow 8)
(define NSPNGFileType 4)
;; CGRectNull: {+inf, +inf, 0, 0} — capture the window's full bounds.
(define rect-null (make-NSRect (make-NSPoint +inf.0 +inf.0) (make-NSSize 0.0 0.0)))

;; AppKit constants.
(define NSWindowStyleMaskTitled+ 15) ; titled+closable+miniaturizable+resizable
(define NSBackingStoreBuffered 2)
(define NSViewWidthSizable 2)
(define NSViewHeightSizable 16)
(define NSApplicationActivationPolicyRegular 0)

(struct mac:webview (window webview delegate closed?-box [thread #:mutable]) #:transparent)

(define (supported?)
  (and (eq? (system-type 'os) 'macosx) webkit #t))

(define (->nsstring s)
  (tell (tell NSString alloc) initWithUTF8String: #:type _string s))

;; window-pointer -> on-close thunk. The delegate runs on whatever thread
;; pumps the close event (usually our pump thread, or the thread calling
;; close for programmatic closes).
(define close-callbacks (make-hasheq))
(define callbacks-sema (make-semaphore 1))
(define (callback-put! window proc)
  (call-with-semaphore callbacks-sema
                       (lambda () (hash-set! close-callbacks window proc))))
(define (callback-take! window)
  (call-with-semaphore callbacks-sema
                       (lambda () (hash-ref close-callbacks window #f))))
(define (callback-remove! window)
  (call-with-semaphore callbacks-sema
                       (lambda () (hash-remove! close-callbacks window))))

(define-objc-class GlazeWindowDelegate
                   NSObject
                   ()
                   (- _void
                      (windowWillClose: [_id notification])
                      (define window
                        (cast (tell notification object) _id _uintptr))
                      (define proc (callback-take! window))
                      (when (procedure? proc)
                        (callback-remove! window)
                        (proc))))

;; One-time NSApplication setup: a non-bundled CLI process has no app object
;; yet, and without Regular activation policy the window never reaches the
;; foreground on modern macOS.
(define app-init-sema (make-semaphore 1))
(define (ensure-app!)
  (call-with-semaphore
   app-init-sema
   (lambda ()
     (define app (tell NSApplication sharedApplication))
     (tellv app setActivationPolicy: #:type _int NSApplicationActivationPolicyRegular)
     (install-standard-menus! app)
     ;; macOS 14+ deprecates activateIgnoringOtherApps: in favor of -activate.
     (if (tell app respondsToSelector: #:type _SEL (selector activate))
         (tellv app activate)
         (tellv app activateIgnoringOtherApps: #:type _bool #t))
     app)))

;; Standard Edit/Window menus with key equivalents. Without an Edit menu a
;; plain NSApp has NO first-responder chain for copy/paste/select-all —
;; Cmd+C/V/X/A silently do nothing inside the WKWebView's text fields, a
;; classic embedding omission. nil-target menu items dispatch to the first
;; responder, which WKWebView implements.
(define (mi title action key)
  (tell (tell NSMenuItem alloc)
        initWithTitle:
        (->nsstring title)
        action:
        #:type _SEL
        action
        keyEquivalent:
        (->nsstring key)))

(define (install-standard-menus! app)
  (define main-menu (tell (tell NSMenu alloc) init))
  ;; Edit menu.
  (define edit-menu (tell (tell NSMenu alloc) initWithTitle: (->nsstring "Edit")))
  (for ([item (in-list
               (list
                (mi "Undo" (selector undo:) "z")
                (mi "Redo" (selector redo:) "Z")
                (mi "Cut" (selector cut:) "x")
                (mi "Copy" (selector copy:) "c")
                (mi "Paste" (selector paste:) "v")
                (mi "Select All" (selector selectAll:) "a")))])
    (tellv edit-menu addItem: #:type _id item))
  (define edit-item (mi "Edit" #f ""))
  (tellv edit-item setSubmenu: #:type _id edit-menu)
  (tellv main-menu addItem: #:type _id edit-item)
  ;; Window menu: Close / Minimize.
  (define window-menu (tell (tell NSMenu alloc) initWithTitle: (->nsstring "Window")))
  (tellv window-menu addItem: #:type _id (mi "Close" (selector performClose:) "w"))
  (tellv window-menu addItem: #:type _id (mi "Minimize" (selector miniaturize:) "m"))
  (define window-item (mi "Window" #f ""))
  (tellv window-item setSubmenu: #:type _id window-menu)
  (tellv main-menu addItem: #:type _id window-item)
  (tellv app setMainMenu: #:type _id main-menu))

;; Run the main run loop in NSDefaultRunLoopMode for dwell-secs. This is the
;; modal-loop idiom ([runMode:beforeDate:]): it services AppKit's event source
;; (mouse/key events reach the window) AND every other main-runloop source —
;; WKWebView's XPC/IPC replies, NSTimers, GCD main-queue callbacks. Fetching
;; events with nextEventMatchingMask: instead waits for AppKit events only,
;; which starves WebKit: page loads stall at estimatedProgress 0.1 forever.
;; Each call runs in a fresh autorelease pool.
(define dwell-secs 0.05)
;; Allocated once (init-convention objects are not autoreleased); passing a
;; fresh NSString per iteration would churn the allocator for no benefit.
(define default-runloop-mode
  (tell (tell NSString alloc) initWithUTF8String: #:type _string "NSDefaultRunLoopMode"))
(define (pump-once app)
  (define pool (tell (tell NSAutoreleasePool alloc) init))
  (tell (tell NSRunLoop mainRunLoop)
        runMode:
        default-runloop-mode
        beforeDate:
        #:type _id
        (tell NSDate dateWithTimeIntervalSinceNow: #:type _double dwell-secs))
  (tellv pool drain))

(define (pump-loop app wv)
  (let loop ()
    (unless (unbox (mac:webview-closed?-box wv))
      (pump-once app)
      ;; Mandatory scheduler yield: when a runloop source is always ready,
      ;; runMode:beforeDate: returns immediately and a yield-less loop would
      ;; monopolize the OS thread, starving every other Racket thread.
      (sleep 0.005)
      (loop))))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:devtools? [devtools? #f]
                      #:on-close [on-close (lambda () (void))])
  (unless (supported?)
    (error 'open-webview "macOS WebView backend unavailable (WebKit failed to load)"))
  (define app (ensure-app!))

  ;; NSRect frame for the window (Cocoa centers it on screen). CGFloat fields
  ;; require inexact values — Racket FFI rejects exact integers for _double.
  (define frame
    (make-NSRect (make-NSPoint 0.0 0.0) (make-NSSize (* 1.0 width) (* 1.0 height))))
  (define window
    (tell (tell NSWindow alloc)
          initWithContentRect:
          #:type _NSRect
          frame
          styleMask:
          #:type _uint
          NSWindowStyleMaskTitled+
          backing:
          #:type _int
          NSBackingStoreBuffered
          defer:
          #:type _bool
          #f))
  (tellv window setTitle: (->nsstring title))
  (tellv window setReleasedWhenClosed: #:type _bool #f)

  ;; WKWebView as the content view, tracking window resizes.
  (define config (tell (tell WKWebViewConfiguration alloc) init))
  (define webview
    (tell (tell WKWebView alloc)
          initWithFrame:
          #:type _NSRect
          frame
          configuration:
          config))
  (tellv webview
         setAutoresizingMask:
         #:type _uint
         (bitwise-ior NSViewWidthSizable NSViewHeightSizable))
  (tellv window setContentView: #:type _id webview)
  ;; #:devtools? makes WKWebView inspectable (macOS 13+); on older systems
  ;; web inspectors need a bundle-local override — ignored here.
  (when (and devtools?
             (tell webview respondsToSelector: #:type _SEL (selector setInspectable:)))
    (tellv webview setInspectable: #:type _bool #t))

  ;; Delegate forwards windowWillClose: to the on-close thunk and flags the
  ;; closed?-box so the pump loop exits. Registry key: the window's pointer.
  (define closed? (box #f))
  (define delegate (tell (tell GlazeWindowDelegate alloc) init))
  (tellv window setDelegate: #:type _id delegate)
  (callback-put! (cast window _id _uintptr)
                 (lambda ()
                   (set-box! closed? #t)
                   (on-close)))

  (tellv window makeKeyAndOrderFront: #:type _id window)
  ;; Re-activate with the window on screen: on modern macOS the pre-window
  ;; activate alone does not always bring the window to the active Space.
  (if (tell app respondsToSelector: #:type _SEL (selector activate))
      (tellv app activate)
      (tellv app activateIgnoringOtherApps: #:type _bool #t))

  (define wv (mac:webview window webview delegate closed? #f))
  (navigate wv url)

  ;; Pump AppKit events until the window closes.
  (set-mac:webview-thread! wv (thread (lambda () (pump-loop app wv))))
  wv)

(define (close wv)
  (unless (unbox (mac:webview-closed?-box wv))
    ;; performClose: routes through windowWillClose:, which runs on-close and
    ;; flags the pump loop to exit.
    (tellv (mac:webview-window wv) performClose:)))

(define (navigate wv url)
  (define nsurl (tell (tell NSURL alloc) initWithString: (->nsstring url)))
  (define request (tell (tell NSURLRequest alloc) initWithURL: #:type _id nsurl))
  (tellv (mac:webview-webview wv) loadRequest: #:type _id request))

;; ---- verification APIs (title / url / capture!) ----
;; These exist so callers — and agents developing Glaze apps — can observe
;; webview state without a human looking at the screen.

(define (title wv)
  (define ns (tell #:type _id (mac:webview-webview wv) title))
  (and (cast ns _id _pointer) (tell #:type _string ns UTF8String)))

(define (url wv)
  (define u (tell #:type _id (mac:webview-webview wv) URL))
  (and (cast u _id _pointer)
       (tell #:type _string (tell #:type _id u absoluteString) UTF8String)))

;; Captures the window to dest (default: a fresh temp .png) and returns the
;; path, or #f when the window is closed or not currently capturable (e.g. it
;; sits on a hidden Space). CGWindowListCreateImage is synchronous and needs
;; no runloop participation.
(define (capture! wv [dest #f])
  (and (not (unbox (mac:webview-closed?-box wv)))
       CGWindowListCreateImage
       (let ()
         (define winnum (tell #:type _intptr (mac:webview-window wv) windowNumber))
         (define img (CGWindowListCreateImage rect-null
                                               kCGWindowListOptionIncludingWindow
                                               (bitwise-and winnum #xFFFFFFFF)
                                               0))
         (and img
              (let* ((pool (tell (tell NSAutoreleasePool alloc) init))
                     (rep (tell (tell NSBitmapImageRep alloc)
                                initWithCGImage:
                                #:type _pointer
                                img))
                     (data (tell rep
                                 representationUsingType:
                                 #:type _int
                                 NSPNGFileType
                                 properties:
                                 #:type _id
                                 #f))
                     (path (or dest (make-temporary-file "glaze-capture-~a.png")))
                     (ok? (tell #:type _bool
                                data
                                writeToFile:
                                (->nsstring (if (string? path) path (path->string path)))
                                atomically:
                                #:type _bool
                                #t)))
                (tellv pool drain)
                (when CGImageRelease (CGImageRelease img))
                (and ok? path))))))
