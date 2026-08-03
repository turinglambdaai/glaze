#lang racket/base

;; macOS WebView backend using Racket's ffi/unsafe/objc (no compiler required).
;;
;; Creates an NSWindow containing a WKWebView and loads the given URL. The objc
;; FFI pattern is the same one used by the Phase 2 tray (NSStatusBar) and
;; demonstrated by soapdog/racket-web-view.
;;
;; STATUS (Phase 3, in progress): the structure mirrors the verified tray
;; backend. CI on macOS exercises it; it cannot run on Windows/Linux hosts.
;; (ffi/unsafe/objc requires Cocoa.)

(require ffi/unsafe
         ffi/unsafe/objc)

(provide open-webview
         supported?
         close
         navigate
         mac:webview?)

(import-class NSString
              NSApplication
              NSWindow
              NSView
              WKWebView
              WKWebViewConfiguration
              WKWebViewConfiguration2
              NSURL
              NSURLRequest)

(struct mac:webview (window webview) #:transparent)

(define (supported?)
  (and (eq? (system-type 'os) 'macosx) #t))

(define (->nsstring s)
  (tell (tell NSString alloc) initWithUTF8String: #:type _string s))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:on-close [on-close (lambda () (void))])
  (unless (supported?)
    (error 'open-webview "macOS WebView backend not available on this platform"))

  ;; Ensure the app is active (create shared application if needed).
  (define app (tell NSApplication sharedApplication))
  (tellv app setActivationPolicy: #:type _int 0) ; NSApplicationActivationPolicyRegular
  (tellv app activateIgnoringOtherApps: #:type _bool #t)

  ;; NSRect frame for the window.
  (define frame (make-NSRect (make-NSPoint 0 0) (make-NSSize width height)))
  (define window
    (tell (tell NSWindow alloc)
          initWithContentRect:
          frame
          styleMask:
          #:type _uint
          15 ; titled + closable + miniaturizable + resizable
          backing:
          #:type _int
          2 ; NSBackingStoreBuffered
          defer:
          #:type _bool
          #f))
  (tellv window setTitle: (->nsstring title))
  (tellv window makeKeyAndOrderFront: #:type _id window)

  ;; Create the WKWebView and add it as the content view.
  (define config (tell (tell WKWebViewConfiguration alloc) init))
  (define webview (tell (tell WKWebView alloc) initWithFrame: frame configuration: config))
  (tellv (tell window contentView) addSubview: #:type _id webview)

  ;; Load the URL.
  (define nsurl (tell (tell NSURL alloc) initWithString: (->nsstring url)))
  (define request (tell (tell NSURLRequest alloc) initWithURL: #:type _id nsurl))
  (tellv webview loadRequest: #:type _id request)

  (mac:webview window webview))

(define (close wv)
  (tellv (mac:webview-window wv) close))

(define (navigate wv url)
  (define nsurl (tell (tell NSURL alloc) initWithString: (->nsstring url)))
  (define request (tell (tell NSURLRequest alloc) initWithURL: #:type _id nsurl))
  (tellv (mac:webview-webview wv) loadRequest: #:type _id request))
