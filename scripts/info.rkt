#lang info

;; Collection-level info inside the single `glaze` package: helper
;; scripts (CI webview e2e) are run directly, never compiled by setup.
(define compile-omit-paths '("webview-e2e.rkt"))
(define test-omit-paths 'all)
