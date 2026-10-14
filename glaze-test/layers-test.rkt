#lang racket/base

;; Layer-module guard: glaze/window, glaze/services, glaze/distribution,
;; glaze/devtools, and glaze/experimental are the 1.0 aggregation layers
;; (docs/architecture-1.0.md). Each layer's headline names must stay
;; requireable — a rename or move upstream fails here instead of breaking
;; applications that bind the layer. The negative half (no unreviewed
;; additions) is enforced by review, as with the core facade guard.
;;
;; glaze/experimental is deliberately guarded looser: its surface may
;; change in any release without a compat baseline, so only each
;; resident's presence is asserted, not a verbatim name set.

(require rackunit
         racket/list
         glaze/window
         glaze/services
         glaze/distribution
         glaze/devtools
         glaze/experimental)

;; ---- window ----
(for ([n (in-list '(open-window webview?
                                webview-close
                                webview-navigate
                                webview-title
                                webview-url
                                webview-capture!
                                webview-closed?
                                webview-supported?
                                webview-window-state
                                webview-set-window-state!
                                webview-save-state!
                                window-state
                                window-state?
                                screen-area
                                default-window-state-path
                                read-window-state
                                write-window-state!
                                normalize-window-state))])
  (check-not-exn (lambda () (dynamic-require 'glaze/window n)) (format "window layer missing: ~a" n)))

;; ---- services ----
(for ([n (in-list '(fs-write-text! fs-read-bytes
                                   make-filesystem-routes
                                   load-store
                                   store-get
                                   store-set!
                                   store-delete!
                                   store-path
                                   open-sqlite-database
                                   sql-select
                                   make-sql-routes
                                   shell-spawn!
                                   shell-output
                                   make-shell-routes
                                   http-request
                                   make-http-routes
                                   log-info
                                   make-glaze-logger
                                   make-log-routes
                                   pick-file
                                   save-file-dialog
                                   dialog-message!
                                   dialog-ask!
                                   tray-supported?
                                   clipboard-set!
                                   notify!
                                   single-instance?
                                   accelerator?
                                   make-global-shortcut-routes
                                   make-hotkey
                                   hotkey-register!
                                   hotkey-supported?
                                   system-information
                                   system-hostname
                                   open-browser))])
  (check-not-exn (lambda () (dynamic-require 'glaze/services n))
                 (format "services layer missing: ~a" n)))

;; ---- distribution ----
(for ([n (in-list '(build-app make-linux-installer
                              signing-keygen
                              sign-bytes
                              verify-bytes
                              sign-file
                              verify-signature
                              sha256-file
                              public-key-fingerprint
                              check-update
                              write-signed-update-manifest
                              verify-file-sha256
                              semver?
                              newer-version?
                              copy-template
                              ensure-public-dir))])
  (check-not-exn (lambda () (dynamic-require 'glaze/distribution n))
                 (format "distribution layer missing: ~a" n)))

;; ---- devtools ----
(for ([n (in-list '(start-server start-dev-server
                                 stop-server
                                 generate-api-declarations
                                 path->mime-type
                                 current-glaze-error-reporter
                                 ffi-lib*
                                 ffi-lib-reason
                                 ffi-search-dirs))])
  (check-not-exn (lambda () (dynamic-require 'glaze/devtools n))
                 (format "devtools layer missing: ~a" n)))

;; ---- experimental (presence only — the surface is unfrozen by charter) ----
(check-not-exn (lambda () (dynamic-require 'glaze/experimental 0)) "experimental layer missing")
(for ([n (in-list '(ensure-url-scheme! auto-launch-set!
                                       auto-launch-enabled?
                                       machine-id
                                       issue-license
                                       validate-license
                                       license-valid?
                                       days-until-expiry))])
  (check-not-exn (lambda () (dynamic-require 'glaze/experimental n))
                 (format "experimental layer missing: ~a" n)))
