#lang racket/base

;; Windows system-integration backend. Clipboard via Win32 FFI; open/reveal
;; via explorer subprocesses; notifications via WinRT toasts driven by
;; Windows PowerShell 5.1 — present on every Windows 10/11 install, so the
;; same blessed-subfront-end pattern as macOS (osascript) / Linux
;; (notify-send) applies: no app bundle, no COM registration. Toasts
;; attribute to PowerShell's own AppUserModelID; a packaged app that wants
;; its own attribution can register an AUMID and swap it in.

(require ffi/unsafe
         racket/file
         racket/string
         racket/system)

(provide supported?
         clipboard-set!
         clipboard-get
         notify!
         open-path
         reveal-path)

(define user32 (ffi-lib "user32"))
(define kernel32 (ffi-lib "kernel32"))

(define OpenClipboard (get-ffi-obj "OpenClipboard" user32 (_fun _pointer -> _bool)))
(define CloseClipboard (get-ffi-obj "CloseClipboard" user32 (_fun -> _bool)))
(define EmptyClipboard (get-ffi-obj "EmptyClipboard" user32 (_fun -> _bool)))
(define GetClipboardData
  (get-ffi-obj "GetClipboardData" user32 (_fun _uintptr -> _pointer)))
(define SetClipboardData
  (get-ffi-obj "SetClipboardData" user32 (_fun _uintptr _pointer -> _pointer)))
(define GlobalAlloc
  (get-ffi-obj "GlobalAlloc" kernel32 (_fun _uint _uintptr -> _pointer)))
(define GlobalLock
  (get-ffi-obj "GlobalLock" kernel32 (_fun _pointer -> _pointer)))
(define GlobalUnlock
  (get-ffi-obj "GlobalUnlock" kernel32 (_fun _pointer -> _bool)))
(define GlobalSize
  (get-ffi-obj "GlobalSize" kernel32 (_fun _pointer -> _uintptr)))
(define GlobalFree
  (get-ffi-obj "GlobalFree" kernel32 (_fun _pointer -> _pointer)))

(define CF_UNICODETEXT 13)
(define GMEM_MOVEABLE 2)

;; UTF-16 helpers.
(define (utf16-bytes s)
  (define cv (bytes-open-converter "UTF-8" "UTF-16LE"))
  (define in (string->bytes/utf-8 s))
  (define-values (out consumed status) (bytes-convert cv in))
  (unless (and (eq? status 'complete) (= consumed (bytes-length in)))
    (error 'clipboard-set! "UTF-16 conversion failed"))
  (bytes-append out #"\0\0"))

;; Decode UTF-16 code units, including surrogate pairs. The previous helper
;; treated each 16-bit unit as a Unicode scalar, corrupting non-BMP text.
(define (wstr->string p)
  (and p
       (let loop ([i 0] [chars '()])
         (define u (ptr-ref p _uint16 i))
         (cond
           [(zero? u) (list->string (reverse chars))]
           [(<= #xD800 u #xDBFF)
            (define v (ptr-ref p _uint16 (add1 i)))
            (if (<= #xDC00 v #xDFFF)
                (let ([cp (+ #x10000
                             (arithmetic-shift (- u #xD800) 10)
                             (- v #xDC00))])
                  (loop (+ i 2) (cons (integer->char cp) chars)))
                (loop (add1 i) (cons #\uFFFD chars)))]
           [(<= #xDC00 u #xDFFF)
            (loop (add1 i) (cons #\uFFFD chars))]
           [else
            (loop (add1 i) (cons (integer->char u) chars))]))))


(define (supported?)
  (and (eq? (system-type 'os) 'windows) #t))

(define (clipboard-set! text)
  (and (OpenClipboard #f)
       (dynamic-wind
         void
         (lambda ()
           (EmptyClipboard)
           (define data (utf16-bytes text))
           (define h (GlobalAlloc GMEM_MOVEABLE (bytes-length data)))
           (and h
                (let ([dst (GlobalLock h)])
                  (cond
                    [(not dst)
                     (GlobalFree h)
                     #f]
                    [else
                     (memcpy dst data (bytes-length data))
                     (GlobalUnlock h)
                     (define result (SetClipboardData CF_UNICODETEXT h))
                     ;; Ownership transfers to the clipboard only on success.
                     (unless result (GlobalFree h))
                     (and result #t)]))))
         (lambda () (CloseClipboard)))))

(define (clipboard-get)
  (cond
    [(not (OpenClipboard #f)) ""]
    [else
     (dynamic-wind
       (lambda () (void))
       (lambda ()
         (define h (GetClipboardData CF_UNICODETEXT))
         (if (not h)
             ""
             (let ()
               (define p (GlobalLock h))
               (define s (wstr->string p))
               (GlobalUnlock h)
               (or s ""))))
       (lambda () (CloseClipboard)))]))

;; The AppUserModelID of the inbox PowerShell shortcut — toasts from an
;; unregistered AUMID are dropped, but this one ships registered on every
;; desktop Windows since 10.
(define powershell-aumid
  "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe")

;; XML text content escaping (& first — otherwise it would double-escape
;; the replacements).
(define (xml-escape s)
  (string-replace
   (string-replace
    (string-replace
     (string-replace (string-replace s "&" "&amp;") "<" "&lt;")
     ">" "&gt;")
    "\"" "&quot;")
   "'" "&apos;"))

(define (toast-visual title body subtitle)
  (define lines
    (append (list title body)
            (if (non-empty-string? subtitle) (list subtitle) '())))
  (define texts
    (apply string-append
           (for/list ([l (in-list lines)]) (format "<text>~a</text>" (xml-escape l)))))
  (format "<toast><visual><binding template=\"ToastGeneric\">~a</binding></visual></toast>"
          texts))

;; PowerShell single-quoted literal: '' is the only escape.
(define (ps-quote s) (string-replace s "'" "''"))

(define (notify! title body subtitle)
  (define ps (find-executable-path "powershell.exe"))
  (and ps
       (let ()
         (define script
           (string-append
            "$ErrorActionPreference = 'Stop'\n"
            "try {\n"
            "  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null\n"
            "  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null\n"
            "  $xml = New-Object Windows.Data.Xml.Dom.XmlDocument\n"
            (format "  $xml.LoadXml('~a')\n" (ps-quote (toast-visual title body subtitle)))
            "  $toast = New-Object Windows.UI.Notifications.ToastNotification $xml\n"
            (format "  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('~a').Show($toast)\n"
                    (ps-quote powershell-aumid))
            "  exit 0\n"
            "} catch {\n"
            "  exit 1\n"
            "}\n"))
         ;; The script file sidesteps command-line quoting for arbitrary
         ;; title/body text (xml-escape already made the XML safe).
         (define path (make-temporary-file "glaze-notify-~a.ps1"))
         (dynamic-wind
           (lambda () (with-output-to-file path
                        (lambda () (display script))
                        #:exists 'replace))
           (lambda ()
             (= 0 (system*/exit-code ps "-NoProfile" "-NonInteractive"
                                     "-ExecutionPolicy" "Bypass"
                                     "-WindowStyle" "Hidden"
                                     "-File" (path->string path))))
           (lambda () (delete-file path))))))

(define (open-path p)
  (define e (find-executable-path "explorer.exe"))
  (and e (system* e p)))

(define (reveal-path p)
  (define e (find-executable-path "explorer.exe"))
  (and e (system* e "/select," p)))
