#lang racket/base

;; macOS-only regression for issue #2. A real opaque NSWindow is placed
;; directly above the target WebView window. The test first proves that AppKit
;; reports the target as fully occluded, then keeps it covered for more than
;; 30 seconds and observes a JavaScript setInterval through document.title.
;;
;; Keep the native machinery here instead of adding test-only surface to the
;; public API. mac:webview-window is an existing backend inspection hook.

(require ffi/unsafe
         ffi/unsafe/objc
         racket/file
         racket/string
         glaze/server
         glaze/webview/main
         (only-in glaze/webview/webview-macos mac:webview-window))

(import-class NSColor NSWindow)

(define-cstruct _NSPoint ([x _double] [y _double]))
(define-cstruct _NSSize ([width _double] [height _double]))
(define-cstruct _NSRect ([origin _NSPoint] [size _NSSize]))

(define NSBackingStoreBuffered 2)
(define NSWindowAbove 1)
(define NSWindowOcclusionStateVisible 2)

(define failures '())

(define (log fmt . args)
  (apply fprintf (current-error-port) (string-append "[occlusion-e2e] " fmt "\n") args))

(define (check! name ok?)
  (printf "[occlusion-e2e] ~a ~a\n" (if ok? "PASS" "FAIL") name)
  (unless ok?
    (set! failures (cons name failures)))
  ok?)

(define (wait-until pred [secs 15])
  (define deadline (+ (current-inexact-milliseconds) (* secs 1000)))
  (let loop ()
    (cond
      [(pred) #t]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else (sleep 0.1) (loop)])))

(define (tick-number wv)
  (define current-title (webview-title wv))
  (define match
    (and (string? current-title)
         (regexp-match #px"^occlusion:([0-9]+)$" current-title)))
  (and match (string->number (cadr match))))

(define public-dir (make-temporary-file "glaze-occlusion-~a" 'directory))
(define stop-server! #f)
(define wv #f)
(define cover #f)

(dynamic-wind
 void
 (lambda ()
   (with-handlers
       ([exn:fail?
         (lambda (e)
           (log "exception: ~a" (exn-message e))
           (set! failures (cons "script completed without exception" failures)))])
     (call-with-output-file (build-path public-dir "index.html")
       (lambda (out)
         (display
          (string-append
           "<!doctype html><meta charset=utf-8><title>occlusion:0</title>"
           "<body style='margin:0;background:#175d7a'>"
           "<script>let tick=0;setInterval(()=>{document.title=`occlusion:${++tick}`},250)</script>")
          out))
       #:exists 'replace)

     (define-values (port stop)
       (start-server #:port 18971 #:public-dir public-dir))
     (set! stop-server! stop)

     (set! wv
           (open-window (format "http://127.0.0.1:~a/" port)
                        #:title "Glaze occlusion regression"
                        #:width 640
                        #:height 480
                        #:background-active? #t))
     (unless (check! "background-active WebView opens" (webview? wv))
       (error 'macos-occlusion-e2e "WebView backend unavailable"))

     (define started?
       (wait-until
        (lambda ()
          (define n (tick-number wv))
          (and n (>= n 4)))))
     (unless (check! "JavaScript interval starts" started?)
       (error 'macos-occlusion-e2e
              "timer did not start; title is ~s"
              (webview-title wv)))

     (define target (mac:webview-window (webview-handle wv)))
     (define target-frame (tell #:type _NSRect target frame))
     (set! cover
           (tell (tell NSWindow alloc)
                 initWithContentRect:
                 #:type _NSRect
                 target-frame
                 styleMask:
                 #:type _uintptr
                 0
                 backing:
                 #:type _uintptr
                 NSBackingStoreBuffered
                 defer:
                 #:type _bool
                 #f))
     (tellv cover setReleasedWhenClosed: #:type _bool #f)
     (tellv cover setOpaque: #:type _bool #t)
     (tellv cover setHasShadow: #:type _bool #f)
     (tellv cover setAlphaValue: #:type _double 1.0)
     (tellv cover
            setBackgroundColor:
            #:type _id
            (tell NSColor
                  colorWithRed:
                  #:type _double
                  0.08
                  green:
                  #:type _double
                  0.11
                  blue:
                  #:type _double
                  0.14
                  alpha:
                  #:type _double
                  1.0))
     ;; Borderless content and frame rectangles are identical, so using the
     ;; target's frame covers its full bounds without introducing title-bar
     ;; geometry differences.
     (tellv cover
            orderWindow:
            #:type _intptr
            NSWindowAbove
            relativeTo:
            #:type _intptr
            (tell #:type _intptr target windowNumber))

     (define (fully-occluded?)
       (and (tell #:type _bool target isVisible)
            (positive?
             (bitwise-and NSWindowOcclusionStateVisible
                          (tell #:type _uintptr cover occlusionState)))
            (zero?
             (bitwise-and NSWindowOcclusionStateVisible
                          (tell #:type _uintptr target occlusionState)))))

     (unless (check! "AppKit reports the covered target as fully occluded"
                     (wait-until fully-occluded? 10))
       (error 'macos-occlusion-e2e
              "could not establish occlusion (target state=~a, cover state=~a)"
              (tell #:type _uintptr target occlusionState)
              (tell #:type _uintptr cover occlusionState)))

     (define before (tick-number wv))
     (log "fully occluded at tick ~a; holding cover for 35 seconds" before)
     (sleep 15)
     (define middle (tick-number wv))
     (define covered-at-middle? (fully-occluded?))
     (sleep 20)
     (define after (tick-number wv))
     (define covered-at-end? (fully-occluded?))
     (log "ticks while covered: before=~a middle=~a after=~a" before middle after)

     (check! "target remains fully occluded after 15 seconds" covered-at-middle?)
     (check! "target remains fully occluded after 35 seconds" covered-at-end?)
     (check! "JavaScript ticks advance during the first covered interval"
             (and before middle (> middle before)))
     (check! "JavaScript ticks continue advancing beyond 30 seconds"
             (and middle after (> after middle)))))
 (lambda ()
   (when cover
     (with-handlers ([exn:fail? (lambda (_) (void))])
       (tellv cover close)))
   (when (webview? wv)
     (with-handlers ([exn:fail? (lambda (_) (void))])
       (webview-close wv)))
   (when stop-server!
     (with-handlers ([exn:fail? (lambda (_) (void))])
       (stop-server!)))
   (when (directory-exists? public-dir)
     (delete-directory/files public-dir))))

(if (null? failures)
    (begin
      (printf "[occlusion-e2e] ALL PASS\n")
      (exit 0))
    (begin
      (printf "[occlusion-e2e] FAILURES: ~a\n"
              (string-join (reverse failures) ", "))
      (exit 1)))
