#lang racket/base

;; glaze/window — windows, webview handles, and window state.
;;
;; An aggregation layer over the windowing modules, per the 1.0 module
;; layout (docs/architecture.md): applications that want the window
;; surface without the full `glaze` facade require this module. The export
;; set is guarded by glaze-test/layers-test, so drift fails CI.
;;
;; `webview-backend`/`webview-handle` are raw backend accessors on the
;; webview struct — internalized behind glaze/webview by G3-S2
;; (docs/api-stability.md), so the reviewed layer no longer re-exports
;; them.

(require (except-in "webview/main.rkt" webview-backend webview-handle)
         "window-state.rkt")

(provide (all-from-out "webview/main.rkt")
         (all-from-out "window-state.rkt"))
