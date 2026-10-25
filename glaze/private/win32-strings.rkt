#lang racket/base

;; Win32 wide-string plumbing for native dialogs. Internalized behind
;; glaze/private by G3-S2 (docs/api-stability.md) — never public API; the
;; webview and sys Windows backends keep their own private copies on
;; purpose (no shared FFI surface between those modules).

(provide wstr
         wstr-parts
         win-filter-string)

(require racket/string)

;; ---- UTF-16 plumbing (Windows wide strings) ----

(define utf16-converter (bytes-open-converter "UTF-8" "UTF-16LE"))

;; platform string -> NUL-terminated UTF-16LE bytes.
(define (wstr s)
  (define in (string->bytes/utf-8 s))
  (define-values (out consumed status) (bytes-convert utf16-converter in))
  (unless (and (eq? status 'complete) (= consumed (bytes-length in)))
    (error 'wstr "UTF-16 conversion failed"))
  (bytes-append out (bytes 0 0)))

;; UTF-16LE bytes -> list of strings split on NUL code units (2 zero bytes —
;; unit-aware, so paths containing code units like U+0100 split correctly).
(define (wstr-parts b)
  (define cv (bytes-open-converter "UTF-16LE" "UTF-8"))
  (let loop ([i 0]
             [acc '()])
    (if (>= (+ i 1) (bytes-length b))
        (reverse acc)
        (if (and (zero? (bytes-ref b i)) (zero? (bytes-ref b (+ i 1))))
            (reverse acc) ; terminating NUL code unit
            (let ([end (let loop2 ([j i])
                         (if (and (zero? (bytes-ref b j)) (zero? (bytes-ref b (+ j 1))))
                             j
                             (loop2 (+ j 2))))])
              (define-values (out consumed status) (bytes-convert cv (subbytes b i end)))
              (loop (+ end 2) (cons (bytes->string/utf-8 out) acc)))))))

;; Win32 filter encoding: "name\0patterns\0" pairs, whole blob
;; double-NUL-terminated. "All files" is appended when no filter matches
;; everything, so the user is never stuck.
(define (win-filter-string filters)
  (string-append (string-join (append (for/list ([f (in-list filters)])
                                        (format "~a\0~a\0" (car f) (string-join (cdr f) ";")))
                                      '("All files\0*.*\0"))
                              "")
                 "\0"))
