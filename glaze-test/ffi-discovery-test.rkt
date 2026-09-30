#lang racket/base

;; ffi-lib* discovery: multi-soname candidates, never-raise, actionable
;; reason. Both behaviors trace to shipped failures — see the module docs
;; (gPTP Studio v1.0.0 crashed on Ubuntu for each of them once).

(require ffi/unsafe
         racket/string
         rackunit
         glaze/ffi-discovery)

;; Success path: a guaranteed-present system library. libc's soname is "6"
;; on glibc Linux, which is the platform family where the multiarch/soname
;; pitfalls live; other platforms are out of scope for this suite.
(when (eq? (system-type 'os) 'unix)
  (define libc (ffi-lib* "libc" '("6" "0.8" "")))
  (check-true (ffi-lib? libc) "libc resolves via soname candidates")
  (check-false (ffi-lib-reason) "reason cleared after a successful load")

  ;; A missing library returns #f, never raises, and the reason names the
  ;; library so support reports stay actionable.
  (define gone (ffi-lib* "glaze-no-such-library-xyz" '("1" "0.8")))
  (check-false gone "missing library -> #f, no raise")
  (check-true (string? (ffi-lib-reason)) "missing library -> reason string")
  (check-true (string-contains? (ffi-lib-reason) "glaze-no-such-library-xyz")
              "reason names the library")
  (check-false (string-contains? (ffi-lib-reason) "\n") "reason is single-line")

  ;; #f inside versions also tries the unversioned name (-dev installs).
  (check-false (ffi-lib* "glaze-no-such-library-xyz" '(#f)) "unversioned candidate -> #f, no raise"))

;; The schedulers pick these at runtime; packaging embeds exactly this list
;; (see glaze/build). Guard the contract so a renamed backend module breaks
;; the build test, not a shipped binary.
(require glaze/build)
(define backends (platform-backend-modules))
(check-equal? (length backends) 3 "one backend each for webview, sys, tray")
(check-true (andmap symbol? backends) "backend module paths are symbols")
(for ([mod (in-list backends)])
  (check-true (string-prefix? (symbol->string mod) "glaze/")
              (format "~a lives in the glaze collection" mod)))
(check-true (case (system-type 'os)
              [(unix) (and (memq 'glaze/webview/webview-linux backends) #t)]
              [(windows) (and (memq 'glaze/webview/webview-windows backends) #t)]
              [(macosx) (and (memq 'glaze/webview/webview-macos backends) #t)]
              [else (and (memq 'glaze/webview/webview-stub backends) #t)])
            "current platform's webview backend is in the embed list")

;; Backend contract: the dispatcher dynamic-requires all 13 names from the
;; current platform's backend, so a missing export breaks the packaged app
;; at the first open-window (webview-linux shipped without focus!/set-menu!
;; exports despite implementing them — caught by exactly this gap).
(define webview-dispatch-names
  '(open-webview supported?
                 close
                 navigate
                 title
                 url
                 capture!
                 set-title!
                 set-size!
                 set-fullscreen!
                 focus!
                 set-menu!
                 closed?))
(when (eq? (system-type 'os) 'unix)
  (for ([name (in-list webview-dispatch-names)])
    (check-not-false (dynamic-require 'glaze/webview/webview-linux name (λ () #f))
                     (format "webview-linux provides ~a" name))))
