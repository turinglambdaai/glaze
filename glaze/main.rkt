#lang racket/base

(require "server.rkt"
         "api.rkt"
         "api-macros.rkt"
         "bridge.rkt"
         "types.rkt"
         "capability.rkt"
         "filesystem.rkt"
         "shell.rkt"
         "store.rkt"
         "system.rkt"
         "path.rkt"
         "http.rkt"
         "sql.rkt"
         "global-shortcut.rkt"
         "log.rkt"
         "events.rkt"
         "hotkey/main.rkt"
         "sys/main.rkt"
         "update.rkt"
         "browser.rkt"
         "assets.rkt"
         "build.rkt"
         "app.rkt"
         "dialogs.rkt"
         "deeplink.rkt"
         "autolaunch.rkt"
         "tray/main.rkt"
         "webview/main.rkt"
         ;; ---- G3-S2 deprecated private-tier shims (one release cycle) ----
         ;; The 22 names below left the reviewed layers in 0.18.0 and are
         ;; scheduled for removal in 0.19.0; see the migration table in
         ;; CHANGELOG.md and the shim register in docs/api-stability.md.
         ;; The backend accessors (webview/tray pairs) still flow from their
         ;; owner modules above; the rest are re-exported from their
         ;; glaze/private homes so 0.x facade consumers keep loading.
         (only-in "dialogs.rkt" default-dialog-backend)
         (only-in "private/dialog-backend.rkt" dialog-backend? make-dialog-backend)
         (only-in "global-shortcut.rkt" default-hotkey-backend)
         (only-in "private/hotkey-backend.rkt" hotkey-backend? make-hotkey-backend)
         (only-in "private/id-allocator.rkt"
                  make-id-allocator
                  id-allocator-next!
                  id-allocator-register!
                  id-allocator-lookup
                  id-allocator-clear!)
         (only-in "private/win32-strings.rkt" wstr wstr-parts win-filter-string)
         (only-in "private/public-assets.rkt"
                  copy-template
                  ensure-public-dir
                  embedded-public-dir
                  public-dir-relative?))

(provide (all-from-out "server.rkt"
                       "api.rkt"
                       "api-macros.rkt"
                       "bridge.rkt"
                       "types.rkt"
                       "capability.rkt"
                       "filesystem.rkt"
                       "shell.rkt"
                       "store.rkt"
                       "system.rkt"
                       "path.rkt"
                       "http.rkt"
                       "sql.rkt"
                       "global-shortcut.rkt"
                       "log.rkt"
                       "events.rkt"
                       "browser.rkt"
                       "assets.rkt"
                       "build.rkt"
                       "sys/main.rkt"
                       "hotkey/main.rkt"
                       "update.rkt"
                       "dialogs.rkt"
                       "deeplink.rkt"
                       "autolaunch.rkt")
         (all-from-out "app.rkt")
         (all-from-out "tray/main.rkt")
         (all-from-out "webview/main.rkt")
         ;; deprecated G3-S2 shims — removal scheduled for 0.19.0
         default-dialog-backend
         dialog-backend?
         make-dialog-backend
         default-hotkey-backend
         hotkey-backend?
         make-hotkey-backend
         make-id-allocator
         id-allocator-next!
         id-allocator-register!
         id-allocator-lookup
         id-allocator-clear!
         wstr
         wstr-parts
         win-filter-string
         copy-template
         ensure-public-dir
         embedded-public-dir
         public-dir-relative?)
