#lang racket/base

;; URL scheme (deep link) registration, three platforms. Deep links let a
;; browser or another app open `myscheme://...` and land in your app.
;;
;;   (ensure-url-scheme! "myapp")  ; idempotent, safe to call at every start
;;
;; Platform reality:
;;   macOS    — scheme handlers are declared in the bundle's Info.plist
;;              (CFBundleURLTypes); `raco glaze build --url-scheme myapp`
;;              writes them at package time. Runtime registration here is a
;;              no-op that reports 'build-time.
;;   Windows  — HKCU\Software\Classes\<scheme>\shell\open\command pointing
;;              at the current executable (user-scope: no admin needed).
;;   Linux    — a desktop entry in ~/.local/share/applications plus
;;              xdg-mime default (degrades gracefully when xdg-mime is
;;              absent — the desktop file is still written).
;;
;; Receiving the URL: the OS launches (or focuses) your executable with the
;; URL as a command-line argument. The established pattern is single
;; instance (glaze/sys) + argv: the first instance parses command-line
;; arguments for the scheme; later launches exit after the lock check.

(require racket/format
         racket/file
         racket/path
         racket/string
         racket/system)

(provide ensure-url-scheme!)

(define (run-ok? . args)
  (define exe (car args))
  (and exe
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (zero? (apply system*/exit-code args)))))

;; Windows: user-scope registry entries under HKCU\Software\Classes.
(define (win-register! scheme exe-path)
  (define reg (find-executable-path "reg.exe" #f))
  (unless reg
    (error 'ensure-url-scheme! "reg.exe not found"))
  (define key (format "HKCU\\Software\\Classes\\~a" scheme))
  (and (run-ok? reg "add" key "/ve" "/d" (format "URL:~a" scheme) "/f")
       (run-ok? reg "add" key "/v" "URL Protocol" "/d" "" "/f")
       (run-ok? reg "add" (format "~a\\shell\\open\\command" key)
                "/ve" "/d" (format "\"~a\" \"%1\"" exe-path) "/f")
       #t))

(define (desktop-value-escape s)
  ;; Desktop Entry string values use backslash escapes for control
  ;; characters. Prevent a user-controlled app name from injecting keys.
  (apply string-append
         (for/list ([c (in-string s)])
           (case c
             [(#\\) "\\\\"]
             [(#\newline) "\\n"]
             [(#\return) "\\r"]
             [(#\tab) "\\t"]
             [else (string c)]))))

(define (desktop-exec-quote s)
  ;; Exec= has its own quoting rules. Inside double quotes, escape characters
  ;; with special meaning so an executable path remains one literal argv[0].
  (string-append
   "\""
   (apply string-append
          (for/list ([c (in-string s)])
            (if (member c '(#\\ #\" #\` #\$))
                (string #\\ c)
                (string c))))
   "\""))

;; Linux: a desktop entry advertising the scheme, registered as its default
;; handler via xdg-mime when available.
(define (lin-register! scheme exe-path app-name)
  (define data-dir
    (or (getenv "XDG_DATA_HOME")
        (build-path (find-system-path 'home-dir) ".local" "share")))
  (define apps-dir (build-path data-dir "applications"))
  (make-directory* apps-dir)
  (define desktop-name (format "glaze-~a.desktop" scheme))
  (define desktop-path (build-path apps-dir desktop-name))
  (call-with-output-file desktop-path
    (lambda (o)
      (fprintf o "[Desktop Entry]\nType=Application\nName=~a\nExec=~a %u\nMimeType=x-scheme-handler/~a;\nNoDisplay=true\n"
               (desktop-value-escape app-name)
               (desktop-exec-quote exe-path)
               scheme))
    #:exists 'replace)
  ;; Best-effort: without xdg-mime the entry is in place but may not be
  ;; picked up until the next desktop-environment rescan.
  (run-ok? (find-executable-path "xdg-mime" #f)
           "default" desktop-name (format "x-scheme-handler/~a" scheme))
  desktop-path)

;; macOS handlers come from CFBundleURLTypes in the packaged Info.plist —
;; declared by `raco glaze build --url-scheme`. Nothing to do at runtime.
(define (mac-register! scheme)
  'build-time)

;; Idempotent registration of `scheme` so this executable receives
;; scheme://... URLs. Returns a symbol describing what happened:
;;   'registry  — Windows registry entries (re)written
;;   'desktop   — Linux desktop entry (re)written
;;   'build-time — macOS: declared in the bundle's Info.plist at build time
(define (ensure-url-scheme! scheme #:app-name [app-name scheme])
  (unless (string? app-name)
    (raise-argument-error 'ensure-url-scheme! "string?" app-name))
  (unless (regexp-match? #rx"^[a-z][a-z0-9+.-]*$" scheme)
    (error 'ensure-url-scheme! "invalid URL scheme: ~a" scheme))
  (case (system-type 'os)
    [(macosx) (mac-register! scheme)]
    [(windows)
     (define exe (find-system-path 'run-file))
     (if (win-register! scheme (path->string exe))
         'registry
         (error 'ensure-url-scheme! "failed to write registry entries for ~a" scheme))]
    [else
     (define exe (find-system-path 'run-file))
     (lin-register! scheme (path->string exe) app-name)
     'desktop]))
