#lang racket/base

;; Launch-at-login ("auto-launch"), three platforms:
;;   macOS   — SMAppService mainAppService (macOS 13+; requires a packaged
;;             .app — registration names the bundle, not the bare exe).
;;             No permission prompt, modern replacement for the deprecated
;;             LSSharedFileList.
;;   Windows — a value in HKCU\Software\Microsoft\Windows\CurrentVersion\Run
;;             (user scope, no admin).
;;   Linux   — an autostart .desktop entry in ~/.config/autostart.
;;
;;   (auto-launch-set! "MyApp" #t)      ; register
;;   (auto-launch-enabled? "MyApp")     ; => #t / #f / 'requires-approval

(require ffi/unsafe
         ffi/unsafe/objc
         racket/format
         racket/file
         racket/path
         racket/string
         racket/system)

(provide auto-launch-set!
         auto-launch-enabled?)

;; ---- macOS (SMAppService, 13+) ----

(define servicemgmt
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement")))

(import-class SMAppService)

;; SMAppServiceStatus values (macOS 13+).
(define SMAppServiceStatusNotRegistered 0)
(define SMAppServiceStatusEnabled 1)
(define SMAppServiceStatusRequiresApproval 2)
(define SMAppServiceStatusNotFound 3)

(define (mac-service)
  (and servicemgmt
       (let ([svc (tell SMAppService mainAppService)])
         (and (cast svc _id _pointer) svc))))

;; => #t / #f / 'requires-approval / 'not-registered / #f (unavailable host)
(define (mac-enabled?)
  (define svc (mac-service))
  (and svc
       (let ([s (tell #:type _int svc status)])
         (case s
           [(0) 'not-registered]
           [(1) #t]
           [(2) 'requires-approval]
           [(3) #f]
           [else #f]))))

(define (mac-set! enabled?)
  (define svc (mac-service))
  (unless svc
    (error 'auto-launch
           "SMAppService needs macOS 13+ and a packaged .app (raco glaze build)"))
  (define before (mac-enabled?))
  (cond
    [enabled?
     (cond
       [(eq? before #t) #t]
       [else
        ;; NSError** is optional. Passing NULL keeps the FFI surface simple;
        ;; status is queried afterwards to distinguish approval from failure.
        (define ok?
          (tell #:type _bool svc
                registerAndReturnError:
                #:type _pointer
                #f))
        (define after (mac-enabled?))
        (cond
          [(eq? after #t) #t]
          [(eq? after 'requires-approval)
           (error 'auto-launch
                  "registration requires approval in System Settings > General > Login Items")]
          [ok? #t]
          [else
           (error 'auto-launch "SMAppService registration failed")])])]
    [else
     (cond
       [(eq? before 'not-registered) #t]
       [else
        (define ok?
          (tell #:type _bool svc
                unregisterAndReturnError:
                #:type _pointer
                #f))
        (define after (mac-enabled?))
        (if (or ok? (eq? after 'not-registered))
            #t
            (error 'auto-launch "SMAppService unregistration failed"))])]))


;; ---- Windows (HKCU Run key via reg.exe) ----

(define win-run-key "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run")

(define (win-enabled? name)
  (define reg (find-executable-path "reg.exe" #f))
  (and reg
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (define out (open-output-string))
         (define code
           (parameterize ([current-output-port out])
             (system*/exit-code reg "query" win-run-key "/v" name)))
         (and (zero? code) #t))))

(define (win-set! name enabled?)
  (define reg (find-executable-path "reg.exe" #f))
  (unless reg (error 'auto-launch "reg.exe not found"))
  (cond
    [enabled?
     (define exe (path->string (find-system-path 'run-file)))
     (unless (zero? (system*/exit-code reg "add" win-run-key "/v" name
                                       "/d" (format "\"~a\"" exe) "/f"))
       (error 'auto-launch "failed to write Run key"))
     #t]
    [else
     (system*/exit-code reg "delete" win-run-key "/v" name "/f")
     #t]))

;; ---- Linux (autostart desktop entry) ----

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

(define (lin-desktop-path name)
  (define config-dir
    (or (getenv "XDG_CONFIG_HOME")
        (build-path (find-system-path 'home-dir) ".config")))
  (build-path config-dir "autostart" (format "~a.desktop" (safe-name name))))

(define (safe-name s)
  (string-join
   (for/list ([c (in-string s)]
              #:when (or (char-alphabetic? c) (char-numeric? c) (eq? c #\-)))
     (string c))
   ""))

(define (lin-enabled? name)
  (file-exists? (lin-desktop-path name)))

(define (lin-set! name enabled?)
  (define p (lin-desktop-path name))
  (if enabled?
      (begin
        (make-directory* (path-only p))
        (call-with-output-file p
          (lambda (o)
            (fprintf o "[Desktop Entry]\nType=Application\nName=~a\nExec=~a\nX-GNOME-Autostart-enabled=true\n"
                     (desktop-value-escape name)
                     (desktop-exec-quote
                      (path->string (find-system-path 'run-file)))))
          #:exists 'replace))
      (when (file-exists? p)
        (delete-file p)))
  #t)

;; ---- public API ----

;; Register / unregister `name` as a launch-at-login item. On macOS the
;; bundle registers itself (name is informational); on Windows `name` is the
;; Run-key value name; on Linux it names the autostart entry.
(define (auto-launch-set! name enabled?)
  (unless (and (string? name) (non-empty-string? name))
    (raise-argument-error 'auto-launch-set! "non-empty-string?" name))
  (unless (boolean? enabled?)
    (raise-argument-error 'auto-launch-set! "boolean?" enabled?))
  (when (and (eq? (system-type 'os) 'unix)
             (zero? (string-length (safe-name name))))
    (error 'auto-launch-set! "name has no characters usable in a desktop filename"))
  (case (system-type 'os)
    [(macosx) (mac-set! enabled?)]
    [(windows) (win-set! name enabled?)]
    [else (lin-set! name enabled?)]))

;; => #t / #f when the backend knows; other values report nuance
;; ('requires-approval on macOS, 'not-registered); #f also when the host
;; cannot know (bare-execute on macOS 12-).
(define (auto-launch-enabled? name)
  (unless (and (string? name) (non-empty-string? name))
    (raise-argument-error 'auto-launch-enabled? "non-empty-string?" name))
  (case (system-type 'os)
    [(macosx) (mac-enabled?)]
    [(windows) (win-enabled? name)]
    [else (lin-enabled? name)]))
