#lang racket/base

;; glaze/services — the capability services an application calls from its
;; page and backend: filesystem scopes, key-value store, SQL, shell, HTTP
;; proxy, logging, dialogs, tray, system commands, shortcuts, and the
;; browser opener. Aggregation layer per the 1.0 module layout; the export
;; set is guarded by glaze-test/layers-test.
;;
;; `tray-backend`/`tray-handle` are raw backend accessors on the tray
;; struct, `default-dialog-backend`/`default-hotkey-backend` are the
;; platform-bound backend instances — internalized behind their owner
;; modules by G3-S2 (docs/api-stability.md), so the reviewed layer no
;; longer re-exports them. The dialog/hotkey struct plumbing, the id
;; allocator, the Win32 string helpers, and the asset internals stopped
;; being provided by their home modules in the same slice.

(require "filesystem.rkt"
         "store.rkt"
         "sql.rkt"
         "shell.rkt"
         "http.rkt"
         "log.rkt"
         (except-in "dialogs.rkt" default-dialog-backend)
         (except-in "tray/main.rkt" tray-backend tray-handle)
         "sys/main.rkt"
         (except-in "global-shortcut.rkt" default-hotkey-backend)
         "hotkey/main.rkt"
         "system.rkt"
         "browser.rkt")

(provide (all-from-out "filesystem.rkt")
         (all-from-out "store.rkt")
         (all-from-out "sql.rkt")
         (all-from-out "shell.rkt")
         (all-from-out "http.rkt")
         (all-from-out "log.rkt")
         (all-from-out "dialogs.rkt")
         (all-from-out "tray/main.rkt")
         (all-from-out "sys/main.rkt")
         (all-from-out "global-shortcut.rkt")
         (all-from-out "hotkey/main.rkt")
         (all-from-out "system.rkt")
         (all-from-out "browser.rkt"))
