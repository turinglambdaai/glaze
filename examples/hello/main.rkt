#lang racket/base

;; Minimal Glaze app: serve public/, open a native webview window, exit when
;; it closes. This is the whole story — no compiler, no Node toolchain.
;;
;; Run: racket examples/hello/main.rkt

(require racket/runtime-path
         glaze)

(define-runtime-path public "public")

(module+ main
  (run-app #:public-dir public
           #:title "Hello Glaze"))
