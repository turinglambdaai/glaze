#lang racket/base

;; Core-facade guard: `glaze/core` is the stable face (the 20-40 entry
;; points real apps touch daily). The provided-name set is asserted
;; verbatim so accidental additions/renames fail CI instead of silently
;; widening the contract. Changing the face is a deliberate act: update
;; this list in the same commit and call it out in the changelog.

(require rackunit
         racket/list
         (only-in glaze/api route?)
         glaze/core)

;; This smoke list keeps helpful per-name failure messages. The exact variable
;; and syntax export set is enforced by public-api-test.rkt.
(define core-names
  (sort (list 'run-app
              'app-quit!
              'app-id
              'app-state
              'current-app
              'open-app-window
              'GET
              'POST
              'PUT
              'DELETE
              'api-response
              'json-response
              'open-window
              'webview-close
              'webview-navigate
              'webview-title
              'webview-url
              'webview-capture!
              'webview-closed?
              'webview-window-state
              'webview-set-window-state!
              'webview-save-state!
              'make-event-bus
              'bus-broadcast!
              'bus-subscribe!
              'log-debug
              'log-info
              'log-warn
              'log-error
              'make-glaze-logger
              'make-file-log-sink
              'load-store
              'store-get
              'store-set!
              'store-delete!
              'make-path-resolver
              'config-dir
              'data-dir
              'cache-dir
              'make-capability
              'make-api-token
              'current-api-token
              'dialog-message!
              'dialog-ask!
              'pick-file
              'save-file-dialog
              'system-information
              'system-hostname
              'start-server
              'stop-server
              'generate-api-declarations)
        symbol<?))

;; Every documented name must be requireable from glaze/core (a delete or
;; rename fails here).
(for ([n (in-list core-names)])
  (check-not-exn (lambda () (dynamic-require 'glaze/core n)) (format "core missing: ~a" n)))

;; smoke: the face's headline entries are what they claim
(check-pred procedure? run-app)
(check-pred route? (GET "core-guard/ping" (lambda (req) (hasheq))))
