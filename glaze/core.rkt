#lang racket/base

;; glaze/core — the stable facade: the entry points real apps touch daily.
;;
;; `glaze` (main) remains the full surface for one more release cycle; at
;; 1.0 it narrows to this curated face plus the layer modules. Everyday
;; names that are NOT here live in their layer modules (webview/, tray/,
;; sys/, ...) or stay reachable from `glaze` unchanged.
;;
;; The core-test guards this face: the exported-name set is asserted
;; verbatim, so renames and accidental additions fail CI instead of
;; silently widening the contract.

(require "app.rkt"
         "api.rkt"
         "api-macros.rkt"
         "assets.rkt"
         "capability.rkt"
         "dialogs.rkt"
         "events.rkt"
         "log.rkt"
         "path.rkt"
         "server.rkt"
         "store.rkt"
         "system.rkt"
         "webview/main.rkt")

;; ---- app lifecycle ----
(provide run-app
         app-quit!
         app-id
         app-state
         current-app
         open-app-window
         ;; ---- HTTP API surface ----
         define-api-routes
         GET
         POST
         PUT
         DELETE
         api-response
         json-response
         ;; ---- webview windows ----
         open-window
         webview-close
         webview-navigate
         webview-title
         webview-url
         webview-capture!
         webview-closed?
         webview-window-state
         webview-set-window-state!
         webview-save-state!
         ;; ---- events ----
         make-event-bus
         bus-broadcast!
         bus-subscribe!
         ;; ---- logging ----
         log-debug
         log-info
         log-warn
         log-error
         make-glaze-logger
         make-file-log-sink
         ;; ---- storage ----
         load-store
         store-get
         store-set!
         store-delete!
         ;; ---- paths ----
         make-path-resolver
         config-dir
         data-dir
         cache-dir
         ;; ---- capabilities / auth ----
         make-capability
         make-api-token
         current-api-token
         ;; ---- dialogs ----
         dialog-message!
         dialog-ask!
         pick-file
         save-file-dialog
         ;; ---- system ----
         system-information
         system-hostname
         ;; ---- devtools ----
         start-server
         stop-server
         generate-api-declarations)
