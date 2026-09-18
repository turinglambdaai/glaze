#lang info

;; CI/helper scripts are executed explicitly by workflows; package setup
;; should not compile them as library modules.
(define compile-omit-paths
  '("webview-e2e.rkt"
    "package-entry-smoke.rkt"))
(define test-omit-paths 'all)
