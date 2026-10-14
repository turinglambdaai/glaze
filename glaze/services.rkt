#lang racket/base

;; glaze/services — the capability services an application calls from its
;; page and backend: filesystem scopes, key-value store, SQL, shell, HTTP
;; proxy, logging, dialogs, tray, system commands, shortcuts, and the
;; browser opener. Aggregation layer per the 1.0 module layout; the export
;; set is guarded by glaze-test/layers-test.

(require "filesystem.rkt"
         "store.rkt"
         "sql.rkt"
         "shell.rkt"
         "http.rkt"
         "log.rkt"
         "dialogs.rkt"
         "tray/main.rkt"
         "sys/main.rkt"
         "global-shortcut.rkt"
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
