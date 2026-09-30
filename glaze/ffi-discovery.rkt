#lang racket/base

;; Shared foreign-library discovery for Glaze's FFI backends (and for Glaze
;; apps with their own native dependencies).
;;
;; Two shipped-failure lessons are baked in here:
;;
;;  - Sonames differ by Linux family: libpcap.so.1 on Fedora/Arch vs
;;    libpcap.so.0.8 on Debian/Ubuntu (the 0.8 soname is kept there for ABI
;;    history). A single version suffix makes an app work on the author's
;;    machine and crash at startup everywhere else — gPTP Studio v1.0.0 did
;;    exactly that on Ubuntu. Pass every family's candidate in `versions`.
;;
;;  - dlopen's search can miss the Debian/Ubuntu multiarch dirs on some
;;    hosts, so absolute candidates are probed as a fallback. (ffi-lib tries
;;    the original name last, so an exact absolute path still loads as-is.)
;;
;; Discovery never raises: a missing library is a *capability* the caller
;; can degrade on (supported? -> #f plus an actionable reason), never a
;; startup crash. Startup paths (--version/--doctor/GUI) must come up
;; without the library and report it; see glaze/webview for the pattern.

(require ffi/unsafe
         racket/list
         racket/string)

(provide ffi-lib*
         ffi-lib-reason
         ffi-search-dirs)

;; "" means the platform default search (dlopen soname lookup); the rest are
;; the common multiarch/lib64 locations probed literally when that fails.
(define ffi-search-dirs
  '("" "/lib/x86_64-linux-gnu/"
       "/usr/lib/x86_64-linux-gnu/"
       "/lib/aarch64-linux-gnu/"
       "/usr/lib/aarch64-linux-gnu/"
       "/usr/lib64/"
       "/usr/lib/"
       "/lib/"))

(define last-reason-box (box #f))

;; Single-line, human-readable reason for the most recent ffi-lib* failure;
;; #f when nothing has failed (or a later load succeeded).
(define (ffi-lib-reason)
  (unbox last-reason-box))

;; Load a foreign library by plain name + soname version candidates.
;;
;;   name     — e.g. "gtk-3" or "pcap" (no lib/.so parts)
;;   versions — soname suffix candidates in family order, e.g. '("1" "0.8")
;;              for libpcap or '("0") for gtk-3; #f inside the list also
;;              tries the unversioned name (what -dev packages install).
;;              A bare string is accepted and treated as one candidate.
;;
;; Returns ffi-lib? or #f. Never raises.
;;
;; Candidates are tried default-search-first for every version, then the
;; absolute fallback dirs — mirroring the original per-backend discovery
;; this module replaces.
(define (ffi-lib* name versions)
  (set-box! last-reason-box #f)
  (define version-candidates
    (if (string? versions)
        (list versions)
        versions))
  (for/or ([dir (in-list ffi-search-dirs)])
    (for/or ([v (in-list version-candidates)])
      (with-handlers ([exn:fail? (λ (e)
                                   (record-reason! e)
                                   #f)])
        (if (string=? dir "")
            (ffi-lib name (list v #f))
            (ffi-lib (format "~alib~a.so~a"
                             dir
                             name
                             (if v
                                 (format ".~a" v)
                                 ""))))))))

;; ffi-lib failure messages are multi-line ("could not load...\n path:...\n
;; system error:...\n context..."); the header lines carry the actionable
;; part (tried path + OS error), the context block is Racket machinery.
(define (record-reason! e)
  (set-box! last-reason-box (one-line (exn-message e))))

(define (one-line s)
  (string-join (for/list ([line (in-list (string-split s "\n"))]
                          #:unless (string=? (string-trim line) ""))
                 (string-trim line))
               "; "))
