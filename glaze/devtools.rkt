#lang racket/base

;; glaze/devtools — development-time tooling: the loopback dev server
;; (the HTTP adapter that carries GLZ1 for hot reload and curl), and FFI
;; discovery diagnostics. Aggregation layer per the 1.0 module layout;
;; the export set is guarded by glaze-test/layers-test. Inspect/doctor
;; grow here as they land.

(require "server.rkt"
         "ffi-discovery.rkt")

(provide (all-from-out "server.rkt")
         (all-from-out "ffi-discovery.rkt"))
