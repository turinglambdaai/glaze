#lang info

;; Single installable package: the repository root IS the package. It
;; provides every collection as a top-level directory — the `glaze`
;; library, the `raco glaze` CLI, the Scribble documentation, and the
;; test suite — so one `raco pkg install glaze` (or `--link .` from a
;; checkout) installs everything.

(define name "glaze")
(define collection 'multi)

(define deps
  '(["base" #:version "9.0"]
    "web-server"
    "web-server-lib"
    "db-lib"
    ;; Tests ship inside this package, so rackunit is a runtime dep.
    "rackunit-lib"))
(define build-deps
  '("scribble-lib"
    "racket-doc"))

;; NOTE: `raco-commands` and `scribblings` are collection-level fields:
;; they live in glaze-cli/info.rkt and glaze-doc/info.rkt respectively.

;; NOTE: Racket's `valid-version?` rejects a trailing ".0" component
;; ("0.8.0" is invalid; "0.8" is the same release).
(define version "0.8")
(define release-version "0.8.0")

;; `raco test --package` otherwise executes every backend implementation as a
;; standalone test module. The dispatcher and platform CI exercise these
;; modules on their matching OS; directly loading a platform FFI backend as a
;; test on a different OS is neither meaningful nor portable.
(define test-omit-paths
  '("glaze/sys/sys-linux.rkt"
    "glaze/sys/sys-macos.rkt"
    "glaze/sys/sys-windows.rkt"
    "glaze/tray/tray-linux.rkt"
    "glaze/tray/tray-macos.rkt"
    "glaze/tray/tray-windows.rkt"
    "glaze/webview/webview-linux.rkt"
    "glaze/webview/webview-macos.rkt"
    "glaze/webview/webview-windows.rkt"))

(define pkg-desc "Build desktop apps with Racket backend and web frontend — a Tauri-like framework for Racket")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)
(define repository "https://github.com/turinglambdaai/glaze")
