#lang info

;; Collection-level info inside the single `glaze` package: examples are
;; run in place (`racket examples/...`), never compiled or tested during
;; package setup.
(define compile-omit-paths
  '("showcase"
    "hello"
    "counter"
    "events"
    "tray"
    "agent-verify.rkt"
    "tray-demo.rkt"
    "webview-demo.rkt"))
(define test-omit-paths 'all)
