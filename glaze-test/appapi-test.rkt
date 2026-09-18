#lang racket/base

;; App-level API tests: menu protocol, dialog helpers, deep links,
;; auto-launch state queries, and — on macOS — a real-window menu-bar e2e
;; that dispatches a native menu selection into a Racket thunk.

(require rackunit
         ffi/unsafe
         ffi/unsafe/objc
         racket/file
         racket/list
         racket/path
         racket/string
         net/http-client
         glaze/dialogs
         glaze/deeplink
         glaze/autolaunch
         glaze/server
         glaze/tray/tray-protocol
         glaze/webview/main)

;; ---- menu protocol (shared with the tray) ----

(define mi (make-menu-item "Open…" #:action (lambda () 'opened)
                           #:accel "CmdOrCtrl+O"))
(check-true (menu-item? mi) "menu-item? recognizes items")
(check-equal? (menu-item-accel mi) "CmdOrCtrl+O" "accel round-trips")
(check-true (menu-separator? (menu-separator)) "separator detection")
(check-false (menu-separator? mi) "regular item is not a separator")
(define m (make-menu "File" (list mi (menu-separator))))
(check-true (menu? m) "menu? recognizes menus")
(check-equal? (menu-title m) "File" "menu title round-trips")

;; ---- dialog helpers ----

(define filter-blob (win-filter-string (list (list "Text" "*.txt" "*.md"))))
(check-true (string-contains? filter-blob "Text\0*.txt;*.md\0") "win filter encodes name+patterns")
(check-true (string-contains? filter-blob "All files\0*.*\0") "win filter appends the all-files entry")

;; UTF-16 round trip incl. a code unit whose low byte is NUL (U+0100) —
;; the parts splitter must be unit-aware, not byte-aware.
(define roundtrip (wstr-parts (wstr "C:\\test\0a\u0100b\0\0")))
(check-equal? roundtrip (list "C:\\test" "a\u0100b") "UTF-16 parts split on NUL code units")

;; ---- deep links ----

(check-exn exn:fail?
           (lambda () (ensure-url-scheme! "1bad-scheme"))
           "invalid scheme raises")
(check-exn exn:fail?
           (lambda () (ensure-url-scheme! "Bad Scheme"))
           "uppercase scheme raises")
(when (eq? (system-type 'os) 'macosx)
  (check-equal? (ensure-url-scheme! "glaze-test-scheme") 'build-time
                "macOS defers registration to the packaged Info.plist"))

(when (eq? (system-type 'os) 'unix)
  (define tmp-data (make-temporary-file "glaze-deeplink-~a" 'directory))
  (define old-data (getenv "XDG_DATA_HOME"))
  (define old-path (getenv "PATH"))
  (dynamic-wind
    (lambda ()
      (putenv "XDG_DATA_HOME" (path->string tmp-data))
      ;; Keep the test a pure file-write exercise; do not let xdg-mime modify
      ;; the runner's desktop defaults.
      (putenv "PATH" ""))
    (lambda ()
      (check-equal?
       (ensure-url-scheme! "glaze-test-scheme" #:app-name "Glaze\nInjected=bad")
       'desktop
       "Linux deep-link registration follows the documented symbol contract")
      (define desktop
        (build-path tmp-data "applications" "glaze-glaze-test-scheme.desktop"))
      (define text (file->string desktop))
      (check-true (string-contains? text "Name=Glaze\\nInjected=bad")
                  "desktop entry escapes newlines in app name")
      (check-false (string-contains? text (string-append "Name=Glaze" "\n" "Injected=bad"))
                   "desktop entry contains no injected key"))
    (lambda ()
      (putenv "XDG_DATA_HOME" old-data)
      (putenv "PATH" old-path)
      (delete-directory/files tmp-data))))

;; ---- auto-launch state queries ----

(define state (auto-launch-enabled? "glaze-api-test"))
(check-true (and (or (boolean? state) (memq state '(requires-approval not-registered))) #t)
            "auto-launch state is a boolean or a nuance tag")

;; Linux registration is a pure file write — exercise the toggle against an
;; overridden XDG_CONFIG_HOME so the test never touches real user state.
(when (eq? (system-type 'os) 'unix)
  (define tmp-cfg (make-temporary-file "glaze-autostart-~a" 'directory))
  (putenv "XDG_CONFIG_HOME" (path->string tmp-cfg))
  (check-false (auto-launch-enabled? "glaze-api-test") "linux: not registered initially")
  (auto-launch-set! "glaze-api-test" #t)
  (check-true (auto-launch-enabled? "glaze-api-test") "linux: registered")
  (check-true (string-contains? (file->string (build-path tmp-cfg "autostart" "glaze-api-test.desktop"))
                                "X-GNOME-Autostart-enabled=true")
              "linux: desktop entry written")
  (auto-launch-set! "glaze-api-test" #f)
  (check-false (auto-launch-enabled? "glaze-api-test") "linux: unregistered")
  (delete-directory/files tmp-cfg))

;; ---- macOS real-window menu e2e ----
;; open -> set custom menu -> poll page load -> perform the native menu
;; action (the same dispatch a real click takes) -> marker file appears ->
;; close -> wait-for-webviews.
;;
;; This test deliberately uses AppKit/Objective-C calls to synthesize the
;; native menu click, so it must never run merely because another platform's
;; WebView backend is available.

(when (and (eq? (system-type 'os) 'macosx)
           (webview-supported?))
  ;; AppKit is loaded by the backend; register the class binding locally so
  ;; the test can query NSApp for the main menu.
  (import-class NSApplication)
  (define e2e-dir (make-temporary-file "glaze-menu-e2e-~a" 'directory))
  (call-with-output-file (build-path e2e-dir "index.html")
                         (lambda (o) (display "<html><head><title>MenuE2E</title></head><body>hi</body></html>" o))
                         #:exists 'replace)
  (define-values (port shutdown) (start-server #:port 18942 #:public-dir e2e-dir))

  (define marker (make-temporary-file "glaze-menu-marker-~a" 'directory))
  (define marker-file (build-path marker "clicked"))
  (define wv
    (open-window (format "http://127.0.0.1:~a/" port)
                 #:title "Menu E2E"
                 #:width 640 #:height 400))
  (check-not-false wv "macOS window opened")
  (when wv
    ;; page commit poll (verification-API discipline)
    (let loop ([deadline (+ (current-inexact-milliseconds) 15000)])
      (unless (or (webview-url wv) (< deadline (current-inexact-milliseconds)))
        (sleep 0.2)
        (loop deadline)))
    (check-true (string-contains? (or (webview-url wv) "") "18942") "page loaded")

    (check-equal? (length (all-webviews)) 1 "one window registered")
    (check-false (webview-closed? wv) "window reports open")

    (webview-set-menu! wv
                       (list (make-menu "Test"
                                        (list (make-menu-item "Ping"
                                                              #:action (lambda ()
                                                                         (call-with-output-file marker-file
                                                                           (lambda (o) (display "x" o))
                                                                           #:exists 'replace))
                                                              #:accel "Cmd+Shift+P")))))
    ;; Fire the same native dispatch a real menu click uses: NSApp
    ;; sendAction:to:from: with the item's own target (a menu-bar click calls
    ;; [target action:withObject:item]; NSMenu
    ;; performActionForItemAtIndex: is a silent no-op for objc-target items
    ;; in this embedding).
    (define app (tell NSApplication sharedApplication))
    (define main-menu (tell #:type _id app mainMenu))
    (define idx (sub1 (tell #:type _int main-menu numberOfItems)))
    (check-true (> idx 0) "custom menu appended to the main menu")
    (define top-item (tell #:type _id main-menu itemAtIndex: #:type _int idx))
    (check-equal? (tell #:type _string (tell #:type _id top-item title) UTF8String)
                  "Test" "custom menu title round-trips")
    (define ping (tell #:type _id (tell #:type _id top-item submenu) itemAtIndex: #:type _int 0))
    (define sent
      (tell #:type _bool app
            sendAction: #:type _SEL (tell #:type _SEL ping action)
            to: #:type _id (tell #:type _id ping target)
            from: #:type _id ping))
    (check-true sent "native dispatch accepted")
    (check-true (file-exists? marker-file) "menu action dispatched into Racket")

    (webview-close wv)
    (check-true (webview-closed? wv) "closed after webview-close")
    (check-true (wait-for-webviews 5) "wait-for-webviews returns once closed"))

  (shutdown)
  (delete-directory/files e2e-dir)
  (delete-directory/files marker))
