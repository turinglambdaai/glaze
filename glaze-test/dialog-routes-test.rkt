#lang racket/base

(require json
         net/http-client
         racket/file
         racket/list
         racket/port
         racket/string
         rackunit
         ffi/unsafe
         glaze/capability
         glaze/dialogs
         glaze/server)

;; ---- fake backend ----

(define calls (box '()))

(define (record! tag args)
  (set-box! calls (append (unbox calls) (list (cons tag args)))))

(define fake-backend
  (make-dialog-backend (lambda (title start filters)
                         (record! 'pick-file (list title start filters))
                         (string->path "/chosen/one.txt"))
                       (lambda (title start filters)
                         (record! 'pick-files (list title start filters))
                         (list (string->path "/chosen/a.txt") (string->path "/chosen/b.txt")))
                       (lambda (title start)
                         (record! 'pick-folder (list title start))
                         #f)
                       (lambda (title start filters default-name)
                         (record! 'save (list title start filters default-name))
                         (string->path "/chosen/saved.txt"))
                       (lambda (title body)
                         (record! 'message (list title body))
                         #t)
                       (lambda (title body)
                         (record! 'ask (list title body))
                         #f)))

;; ---- capability-gated routes ----

(define root (make-temporary-file "glaze-dialog-~a" 'directory))
(define outside (make-temporary-file "glaze-dialog-outside-~a" 'directory))
(define authority
  (make-capability "main"
                   (list (path-permission 'dialog:open #:allow (list root))
                         (path-permission 'dialog:save #:allow (list root))
                         'dialog:message
                         'dialog:ask)))
(define token "dialog-token")
(define port 18986)
(define-values (_port shutdown)
  (start-server #:port port
                #:public-dir root
                #:api-token token
                #:capability authority
                #:api (make-dialog-routes #:backend fake-backend)))

(define (call method path [body #f] #:token? [token? #t])
  (define data (and body (string->bytes/utf-8 (jsexpr->string body))))
  (define-values (status headers in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port port
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers (append (if data
                                         '("Content-Type: application/json")
                                         '())
                                     (if token?
                                         (list (string-append "X-Glaze-Token: " token))
                                         '()))))
  (define response-bytes (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status) response-bytes))

;; single open inside the scoped start directory
(let-values ([(status body)
              (call "POST"
                    "/api/dialog/open"
                    (hasheq 'title
                            "Pick"
                            'start
                            (path->string root)
                            'filters
                            (list (hasheq 'name "Text" 'extensions (list "txt" "*.md")))))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref (bytes->jsexpr body) 'path) "/chosen/one.txt")
  (define call-args (rest (first (unbox calls))))
  (check-equal? (first call-args) "Pick")
  (check-equal? (third call-args)
                '(("Text" "*.txt" "*.md"))
                "bare extensions gain the *. prefix, globs pass through"))

;; multiple open returns a list
(let-values ([(status body)
              (call "POST" "/api/dialog/open" (hasheq 'start (path->string root) 'multiple #t))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref (bytes->jsexpr body) 'paths) '("/chosen/a.txt" "/chosen/b.txt")))

;; folder cancel maps to null
(let-values ([(status body)
              (call "POST" "/api/dialog/open" (hasheq 'start (path->string root) 'folder #t))])
  (check-true (string-contains? status "200"))
  (check-false (hash-ref (bytes->jsexpr body) 'path)))

;; save with a default name
(let-values ([(status body) (call "POST"
                                  "/api/dialog/save"
                                  (hasheq 'start (path->string root) 'defaultName "notes.txt"))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref (bytes->jsexpr body) 'path) "/chosen/saved.txt")
  (define call-args (rest (last (filter (lambda (c) (eq? (first c) 'save)) (unbox calls)))))
  (check-equal? (fourth call-args) "notes.txt"))

;; message and ask
(let-values ([(status body)
              (call "POST" "/api/dialog/message" (hasheq 'title "Hello" 'body "World"))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref (bytes->jsexpr body) 'ok)))
(let-values ([(status body)
              (call "POST" "/api/dialog/ask" (hasheq 'title "Proceed?" 'body "Really?"))])
  (check-true (string-contains? status "200"))
  (check-false (hash-ref (bytes->jsexpr body) 'answer)))

;; permission enforcement: outside the scoped start directory, and requests
;; without a start (no resource to authorize) are both denied
(let-values ([(status _) (call "POST"
                               "/api/dialog/open"
                               (hasheq 'start (path->string (build-path outside "x.txt"))))])
  (check-true (string-contains? status "403") "start outside the scope is denied"))
(let-values ([(status _) (call "POST" "/api/dialog/open" (hasheq))])
  (check-true (string-contains? status "403") "no start directory means nothing to authorize"))
(let-values ([(status _) (call "POST" "/api/dialog/message" (hasheq 'title "x") #:token? #f)])
  (check-true (string-contains? status "401")))

;; validation
(let-values ([(status _)
              (call "POST" "/api/dialog/open" (hasheq 'start (path->string root) 'multiple "yes"))])
  (check-true (string-contains? status "400") "non-boolean multiple is a client error"))
(let-values ([(status _)
              (call "POST"
                    "/api/dialog/open"
                    (hasheq 'start (path->string root) 'filters (list (hasheq 'name "X"))))])
  (check-true (string-contains? status "400") "filter entries need extensions"))
(let-values ([(status _) (call "POST" "/api/dialog/message" (hasheq 'body "no title"))])
  (check-true (string-contains? status "400") "message requires a title"))

;; generated client
(let-values ([(_status body) (call "GET" "/glaze/api.js" #f #:token? #f)])
  (define js (bytes->string/utf-8 body))
  (check-true (string-contains? js "dialogOpen"))
  (check-true (string-contains? js "dialogSave"))
  (check-true (string-contains? js "dialogMessage"))
  (check-true (string-contains? js "dialogAsk")))

(shutdown)

;; a capability without dialog permissions hides the routes
(define authority-quiet (make-capability "quiet" (list 'os:read)))
(define-values (_p2 shutdown2)
  (start-server #:port 18987
                #:public-dir root
                #:api-token token
                #:capability authority-quiet
                #:api (make-dialog-routes #:backend fake-backend)))
(let-values ([(_status headers in)
              (http-sendrecv "127.0.0.1" "/glaze/api.js" #:port 18987 #:ssl? #f)])
  (define js (bytes->string/utf-8 (port->bytes in)))
  (close-input-port in)
  (check-false (string-contains? js "dialogOpen") "unauthorized routes are hidden"))
(shutdown2)

(delete-directory/files root)
(delete-directory/files outside)

;; ---- real message box (Windows only: interactive CI + developer hosts) ----

;; A native modal box parks this place's only OS thread, so the closer must
;; be a separate process: PowerShell finds the dialog window (#32770 is
;; the classic dialog class) and posts WM_CLOSE after a short delay.
(when (eq? (system-type 'os) 'windows)
  (define closer-script
    (string-append
     "Add-Type @'\n"
     "using System;using System.Runtime.InteropServices;\n"
     "public class W { [DllImport(\"user32.dll\")] public static extern IntPtr FindWindow(string c,string n); [DllImport(\"user32.dll\")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);}\n"
     "'@\n"
     "Start-Sleep -Seconds 3\n"
     "$h=[W]::FindWindow(\"#32770\",\"Glaze test\")\n"
     "if($h -ne [IntPtr]::Zero){[W]::PostMessage($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null; exit 0} else { exit 1 }\n"))
  (define script-path (make-temporary-file "glaze-close-box-~a.ps1"))
  (call-with-output-file script-path (lambda (o) (display closer-script o)) #:exists 'replace)
  (define ps (find-executable-path "powershell.exe"))
  (define-values (proc out in err)
    (subprocess #f
                #f
                #f
                ps
                "-NoProfile"
                "-NonInteractive"
                "-ExecutionPolicy"
                "Bypass"
                "-File"
                (path->string script-path)))
  (define result
    (with-handlers ([exn:fail? (lambda (e) 'raised)])
      (dialog-message! "Glaze test" "auto-dismissed")))
  (subprocess-wait proc)
  (define closer-code (subprocess-status proc))
  (when (file-exists? script-path)
    (delete-file script-path))
  (check-true (boolean? result) "dialog-message! returns a boolean after dismissal")
  (check-equal? closer-code 0 "the box appeared and was closed from outside"))
