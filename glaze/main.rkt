#lang racket/base

;; Public application facade.
;;
;; New applications should normally `(require glaze)` rather than depend on
;; platform backend modules or the repository's internal layout.  The facade
;; remains deliberately broad during the 0.x stabilization period so existing
;; focused imports and exported bindings keep working while public/internal
;; boundaries are documented and tested.
;;
;; See docs/architecture.md for the dependency and stability rules.

(require "server.rkt"
         "api.rkt"
         "api-macros.rkt"
         "events.rkt"
         "sys/main.rkt"
         "update.rkt"
         "browser.rkt"
         "assets.rkt"
         "build.rkt"
         "app.rkt"
         "license.rkt"
         "dialogs.rkt"
         "deeplink.rkt"
         "autolaunch.rkt"
         "tray/main.rkt"
         "webview/main.rkt")

(provide (all-from-out "server.rkt" "api.rkt" "api-macros.rkt" "events.rkt"
                       "browser.rkt" "assets.rkt" "build.rkt" "sys/main.rkt"
                       "update.rkt" "license.rkt" "dialogs.rkt" "deeplink.rkt"
                       "autolaunch.rkt")
         (all-from-out "app.rkt")
         (all-from-out "tray/main.rkt")
         (all-from-out "webview/main.rkt"))
