#lang racket/base

;; macOS system-integration backend. Clipboard via NSPasteboard FFI;
;; notifications and open/reveal via the platform's blessed subprocess
;; front-ends (osascript / open) — universally present, no bundle required
;; (UNUserNotificationCenter would need a signed app bundle).

(require ffi/unsafe
         ffi/unsafe/objc
         racket/string
         racket/system)

(provide supported?
         clipboard-set!
         clipboard-get
         notify!
         open-path
         reveal-path)

;; Racket only links Foundation; AppKit classes (NSPasteboard, ...) are
;; NULL until the framework is loaded — WebKit happens to pull it in for
;; the webview backends, so anything using AppKit directly must load it.
(define appkit (ffi-lib "/System/Library/Frameworks/AppKit.framework/AppKit"))

(import-class NSString NSPasteboard NSArray)

(define (supported?)
  (and (eq? (system-type 'os) 'macosx) #t))

(define (->nsstring s)
  (tell (tell NSString alloc) initWithUTF8String: #:type _string s))

(define (clipboard-set! text)
  (define pb (tell NSPasteboard generalPasteboard))
  (and pb
       (let ()
         (tellv pb clearContents)
         ;; arrayWithObject: — NSArray has no initWithObjects:forKeys:
         (define arr (tell NSArray arrayWithObject: #:type _id (->nsstring text)))
         (> (tell #:type _uintptr pb writeObjects: #:type _id arr) 0))))

(define (clipboard-get)
  (define pb (tell NSPasteboard generalPasteboard))
  (and pb
       (let ()
         (define s (tell pb stringForType:
                         #:type _id (->nsstring "public.utf8-plain-text")))
         (if (cast s _id _pointer)
             (tell #:type _string s UTF8String)
             ""))))

(define (notify! title body subtitle)
  (define osa (find-executable-path "osascript"))
  (define script
    (string-append
     "on run argv\n"
     "  set bodyText to item 1 of argv\n"
     "  set titleText to item 2 of argv\n"
     "  set subtitleText to item 3 of argv\n"
     "  if subtitleText is \"\" then\n"
     "    display notification bodyText with title titleText\n"
     "  else\n"
     "    display notification bodyText with title titleText subtitle subtitleText\n"
     "  end if\n"
     "end run"))
  ;; User-controlled notification text travels as argv, never as AppleScript
  ;; source, so quotes/backslashes cannot change the script.
  (and osa (system* osa "-e" script "--" body title subtitle)))

(define (open-path p)
  (define o (find-executable-path "open"))
  (and o (system* o p)))

(define (reveal-path p)
  (define o (find-executable-path "open"))
  (and o (system* o "-R" p)))
