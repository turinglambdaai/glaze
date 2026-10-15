#lang racket/base

;; glaze/experimental — capabilities that are shipped but NOT frozen.
;;
;; Unlike the layer modules, nothing here is under a stability promise:
;; the surface may change in any release without a compat baseline, which
;; is exactly why these live apart. Current residents and why:
;;
;;   deeplink    — OS URL-scheme handover; per-OS behavior (single-instance
;;                 handover, browser capture) still varies and may be
;;                 reshaped by product needs.
;;   autolaunch  — login-item integration; platform APIs differ widely and
;;                 the surface has not been exercised across all three OSes
;;                 by a shipped product.
;;
;; A module graduates out by surviving a release cycle unchanged with real
;; product usage; it then joins its layer module and this list shrinks.

(require "deeplink.rkt"
         "autolaunch.rkt")

(provide (all-from-out "deeplink.rkt")
         (all-from-out "autolaunch.rkt"))
