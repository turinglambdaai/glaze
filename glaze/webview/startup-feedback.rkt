#lang racket/base

;; User-visible startup diagnostics that do not depend on the WebView itself.
;; A packaged Windows Glaze application is built with `raco exe --gui`, so it
;; may have no console where stderr is visible. When native WebView startup
;; fails we therefore show a platform-level error dialog before propagating
;; the exception. CI/automation skips dialogs to avoid blocking unattended
;; runs; the exception text remains the source of truth in logs.

(require ffi/unsafe
         racket/string
         racket/system)

(provide show-webview-startup-error!)

(define (dialog-enabled?)
  (and (not (getenv "CI"))
       (not (getenv "GITHUB_ACTIONS"))
       (not (equal? (getenv "GLAZE_NO_STARTUP_DIALOG") "1"))))

;; ---- Windows: MessageBoxW, available before WebView2 exists ------------

(define (string->utf16-pointer s)
  (define cv (bytes-open-converter "UTF-8" "UTF-16LE"))
  (define-values (out consumed status)
    (bytes-convert cv (string->bytes/utf-8 s)))
  (bytes-close-converter cv)
  (unless (and (eq? status 'complete)
               (= consumed (bytes-length (string->bytes/utf-8 s))))
    (error 'startup-feedback "UTF-16 conversion failed"))
  (define p (malloc (+ (bytes-length out) 2) 'raw))
  (memcpy p out (bytes-length out))
  (ptr-set! p _uint16 (quotient (bytes-length out) 2) 0)
  p)

(define (windows-dialog title message)
  (define user32 (ffi-lib "user32"))
  (define MessageBoxW
    (get-ffi-obj "MessageBoxW"
                 user32
                 (_fun _pointer _pointer _pointer _uint -> _int)))
  (define title-p (string->utf16-pointer title))
  (define message-p (string->utf16-pointer message))
  (dynamic-wind
    void
    (lambda ()
      ;; MB_OK | MB_ICONERROR | MB_SETFOREGROUND
      (MessageBoxW #f message-p title-p (bitwise-ior #x00000000 #x00000010 #x00010000)))
    (lambda ()
      (free title-p)
      (free message-p))))

;; ---- macOS: osascript uses the system dialog service -------------------

(define (applescript-escape s)
  (string-replace (string-replace (string-replace s "\\" "\\\\") "\"" "\\\"")
                  "\n" "\\n"))

(define (macos-dialog title message)
  (define osa (find-executable-path "osascript" #f))
  (and osa
       (system* osa
                "-e"
                (format "display alert \"~a\" message \"~a\" as critical buttons {\"OK\"} default button \"OK\""
                        (applescript-escape title)
                        (applescript-escape message)))))

;; ---- Linux: use the desktop's ordinary dialog helper when available ----

(define (linux-dialog title message)
  (cond
    [(find-executable-path "zenity" #f)
     => (lambda (zenity)
          (system* zenity "--error"
                   (string-append "--title=" title)
                   "--width=640"
                   (string-append "--text=" message)))]
    [(find-executable-path "kdialog" #f)
     => (lambda (kdialog)
          (system* kdialog "--error" message "--title" title))]
    [else #f]))

(define (show-webview-startup-error! message)
  (when (dialog-enabled?)
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (case (system-type 'os)
        [(windows) (windows-dialog "Glaze cannot start" message)]
        [(macosx) (macos-dialog "Glaze cannot start" message)]
        [(unix) (linux-dialog "Glaze cannot start" message)]
        [else #f])))
  (void))
