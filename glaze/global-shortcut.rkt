#lang racket/base

;; Tauri-style global shortcuts: a capability-gated frontend API over
;; glaze/hotkey. Accelerators look like "CmdOrCtrl+Shift+D"; registration
;; scopes are exact accelerators or explicit regular expressions, and each
;; trigger reaches the page as a `global-shortcut` SSE event.

(require racket/list
         racket/match
         racket/string
         net/url
         web-server/http/request-structs
         "api.rkt"
         "capability.rkt"
         "events.rkt"
         "hotkey/main.rkt")

(provide string->hotkey
         hotkey->string
         accelerator?
         make-hotkey-backend
         hotkey-backend?
         default-hotkey-backend
         accelerator-permission
         make-global-shortcut-routes)

;; ---- accelerator parsing ----

;; Modifier spellings are case-insensitive. CommandOrControl resolves per
;; platform: cmd on macOS, ctrl elsewhere (Tauri semantics).
(define modifier-aliases
  '(("command" . cmd) ("cmd" . cmd)
                      ("super" . cmd)
                      ("meta" . cmd)
                      ("control" . ctrl)
                      ("ctrl" . ctrl)
                      ("option" . alt)
                      ("alt" . alt)
                      ("shift" . shift)))

(define (platform-cmd-modifier)
  (if (eq? (system-type 'os) 'macosx) 'cmd 'ctrl))

(define named-key-aliases
  '(["space" Space] ["tab" Tab]
                    ["enter" Enter]
                    ["return" Enter]
                    ["escape" Escape]
                    ["esc" Escape]
                    ["backspace" Backspace]
                    ["delete" Delete]
                    ["del" Delete]
                    ["insert" Insert]
                    ["home" Home]
                    ["end" End]
                    ["pageup" PageUp]
                    ["page-up" PageUp]
                    ["pagedown" PageDown]
                    ["page-down" PageDown]
                    ["up" Up]
                    ["down" Down]
                    ["left" Left]
                    ["right" Right]
                    ["capslock" CapsLock]
                    ["caps-lock" CapsLock]
                    ["numlock" NumLock]
                    ["num-lock" NumLock]
                    ["scrolllock" ScrollLock]
                    ["scroll-lock" ScrollLock]
                    ["printscreen" PrintScreen]
                    ["print-screen" PrintScreen]
                    ["pause" Pause]
                    ["comma" Comma]
                    ["period" Period]
                    ["fullstop" Period]
                    ["slash" Slash]
                    ["backslash" Backslash]
                    ["semicolon" Semicolon]
                    ["quote" Quote]
                    ["apostrophe" Quote]
                    ["backquote" Backquote]
                    ["grave" Backquote]
                    ["backtick" Backquote]
                    ["bracketleft" BracketLeft]
                    ["bracket-left" BracketLeft]
                    ["bracketright" BracketRight]
                    ["bracket-right" BracketRight]
                    ["minus" Minus]
                    ["equal" Equal]
                    ["numpad0" Numpad0]
                    ["numpad1" Numpad1]
                    ["numpad2" Numpad2]
                    ["numpad3" Numpad3]
                    ["numpad4" Numpad4]
                    ["numpad5" Numpad5]
                    ["numpad6" Numpad6]
                    ["numpad7" Numpad7]
                    ["numpad8" Numpad8]
                    ["numpad9" Numpad9]
                    ["numpadadd" NumpadAdd]
                    ["numpadsubtract" NumpadSubtract]
                    ["numpadminus" NumpadSubtract]
                    ["numpadmultiply" NumpadMultiply]
                    ["numpaddivide" NumpadDivide]
                    ["numpadenter" NumpadEnter]
                    ["numpaddecimal" NumpadDecimal]))

;; lowercase alias -> canonical key symbol
(define key-aliases
  (let ()
    (define entries
      (append named-key-aliases
              ;; bare and KeyA-style letters
              (for/list ([c (in-string "abcdefghijklmnopqrstuvwxyz")])
                (list (string c) (string->symbol (string (char-upcase c)))))
              (for/list ([c (in-string "abcdefghijklmnopqrstuvwxyz")])
                (list (string-append "key" (string c)) (string->symbol (string (char-upcase c)))))
              ;; bare and DigitN-style digits
              (for/list ([c (in-string "0123456789")])
                (list (string c) (string->symbol (string c))))
              (for/list ([c (in-string "0123456789")])
                (list (string-append "digit" (string c)) (string->symbol (string c))))
              ;; lowercase and canonical F-keys
              (for/list ([n (in-range 1 25)])
                (list (format "f~a" n) (string->symbol (format "F~a" n))))
              (for/list ([n (in-range 1 25)])
                (list (format "F~a" n) (string->symbol (format "F~a" n))))))
    (make-hash (map (lambda (e) (cons (first e) (second e))) entries))))

;; Parse an accelerator string into a hotkey, or #f. Every part must be a
;; known modifier or key; "CmdOrCtrl" resolves to the platform modifier.
(define (string->hotkey s)
  (and (string? s)
       (<= (string-length s) 256)
       (not (string=? s ""))
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (define parts (map string-downcase (string-split (string-trim s) "+" #:trim? #f)))
         (and (andmap non-empty-string? parts)
              (let parse ([rest parts]
                          [mods '()])
                (cond
                  [(null? rest) #f]
                  [(null? (cdr rest))
                   (define key (hash-ref key-aliases (car rest) #f))
                   (and key (make-hotkey mods key))]
                  [else
                   (define m (car rest))
                   (define mod
                     (cond
                       [(or (string=? m "commandorcontrol") (string=? m "cmdorctrl"))
                        (platform-cmd-modifier)]
                       [(assoc m modifier-aliases)
                        =>
                        cdr]
                       [else #f]))
                   (and mod (parse (cdr rest) (cons mod mods)))]))))))

(define (accelerator? s)
  (and (string->hotkey s) #t))

;; Canonical display form, e.g. "Ctrl+Shift+D" / "Cmd+Shift+D".
(define modifier-names '((cmd . "Cmd") (ctrl . "Ctrl") (alt . "Alt") (shift . "Shift")))

(define (hotkey->string hk)
  (string-join (append (for/list ([m (in-list (hotkey-mods hk))])
                         (cdr (assq m modifier-names)))
                       (list (symbol->string (hotkey-key hk))))
               "+"))

;; ---- backend injection ----

;; Backends are values so tests (and apps with their own dispatch policy)
;; can substitute a fake. default-hotkey-backend delegates to the platform
;; backend selected by glaze/hotkey/main.
(struct hotkey-backend (supported? register! unregister! unregister-all! registered?))

;; Explicit constructor: `provide` cannot forward-reference the implicit
;; struct constructor (same shape as make-capability in capability.rkt).
(define (make-hotkey-backend supported? register! unregister! unregister-all! registered?)
  (unless (andmap procedure? (list supported? register! unregister! unregister-all! registered?))
    (raise-argument-error 'make-hotkey-backend
                          "list of procedures"
                          (list supported? register! unregister! unregister-all! registered?)))
  (hotkey-backend supported? register! unregister! unregister-all! registered?))

(define default-hotkey-backend
  (hotkey-backend hotkey-supported?
                  hotkey-register!
                  hotkey-unregister!
                  hotkey-unregister-all!
                  hotkey-registered?))

;; ---- scoped permission ----

;; Accelerator scopes match the canonical form of both the declared pattern
;; and the requested resource, so "COMMANDORCONTROL+shift+d" and
;; "CmdOrCtrl+Shift+D" authorize the same hotkey on the same platform.
;; Plain strings must parse; regexps match against canonical accelerators.
(define (accelerator-permission id #:allow allowed-patterns #:deny [denied-patterns '()])
  (define (pattern? value)
    (or (string? value) (and (regexp? value) (not (byte-regexp? value)))))
  (unless (and (list? allowed-patterns) (andmap pattern? allowed-patterns))
    (raise-argument-error 'accelerator-permission "list of accelerators or regexps" allowed-patterns))
  (unless (and (list? denied-patterns) (andmap pattern? denied-patterns))
    (raise-argument-error 'accelerator-permission "list of accelerators or regexps" denied-patterns))
  (define (canonicalize who pattern)
    (cond
      [(string? pattern)
       (define hk (string->hotkey pattern))
       (unless hk
         (raise-arguments-error 'accelerator-permission
                                "permission pattern is not a valid accelerator"
                                who
                                pattern))
       (hotkey->string hk)]
      [else pattern]))
  (define allowed (map (lambda (p) (canonicalize "allow" p)) allowed-patterns))
  (define denied (map (lambda (p) (canonicalize "deny" p)) denied-patterns))
  (scoped-permission id
                     (lambda (resource)
                       (and (string? resource)
                            (let ([hk (string->hotkey resource)])
                              (and hk
                                   (let ([canonical (hotkey->string hk)])
                                     (define (matches? pattern)
                                       (if (string? pattern)
                                           (string=? pattern canonical)
                                           (and (regexp-match? pattern canonical) #t)))
                                     (and (for/or ([pattern (in-list allowed)])
                                            (matches? pattern))
                                          (not (for/or ([pattern (in-list denied)])
                                                 (matches? pattern)))))))))))

;; ---- routes ----

(define missing (gensym 'missing))

(define (bad-parameter message)
  (raise (exn:fail:glaze:bad-param message (current-continuation-marks))))

(define (body-hash req)
  (define body (request-json-body req))
  (unless (hash? body)
    (bad-parameter "body: expected a JSON object"))
  body)

(define (body-accelerator req)
  (define accel (hash-ref (body-hash req) 'accelerator missing))
  (cond
    [(eq? accel missing) (bad-parameter "accelerator: missing")]
    [(not (string? accel)) (bad-parameter "accelerator: expected a string")]
    [else accel]))

(define (query-accelerator req)
  (define accel
    (for/or ([kv (in-list (url-query (request-uri req)))])
      (and (eq? (car kv) 'accelerator) (cdr kv))))
  (match accel
    [(? string?) accel]
    [_ (bad-parameter "accelerator: missing query parameter")]))

(define (make-global-shortcut-routes #:prefix [prefix "api/global-shortcut"]
                                     #:backend [backend default-hotkey-backend]
                                     #:events [event-bus #f])
  (unless (and (string? prefix) (not (string=? prefix "")))
    (raise-argument-error 'make-global-shortcut-routes "non-empty-string?" prefix))
  (unless (hotkey-backend? backend)
    (raise-argument-error 'make-global-shortcut-routes "hotkey-backend?" backend))
  (when (and event-bus (not (event-bus? event-bus)))
    (raise-argument-error 'make-global-shortcut-routes "(or/c #f event-bus?)" event-bus))
  (define be-supported? (hotkey-backend-supported? backend))
  (define be-register! (hotkey-backend-register! backend))
  (define be-unregister! (hotkey-backend-unregister! backend))
  (define be-unregister-all! (hotkey-backend-unregister-all! backend))
  (define be-registered? (hotkey-backend-registered? backend))
  (define (endpoint name)
    (string-append (string-trim prefix "/") "/" name))
  (define (body-hotkey req)
    (define accel (body-accelerator req))
    (define hk (string->hotkey accel))
    (unless hk
      (bad-parameter (format "accelerator: invalid accelerator ~v" accel)))
    hk)
  (define (query-hotkey req)
    (define accel (query-accelerator req))
    (define hk (string->hotkey accel))
    (unless hk
      (bad-parameter (format "accelerator: invalid accelerator ~v" accel)))
    hk)
  (define (dispatch-thunk hk)
    (lambda ()
      (when event-bus
        (bus-broadcast! event-bus 'global-shortcut (hasheq 'accelerator (hotkey->string hk))))))
  (list
   (POST
    (endpoint "register")
    (lambda (req)
      (define hk (body-hotkey req))
      (define already (be-registered? hk))
      (define ok (or already (be-register! hk (dispatch-thunk hk))))
      (hasheq 'ok (and ok #t) 'accelerator (hotkey->string hk) 'alreadyRegistered (and already #t)))
    #:permission 'global-shortcut:register
    #:resource (lambda (req) (body-accelerator req)))
   (POST (endpoint "unregister")
         (lambda (req)
           (define hk (body-hotkey req))
           (hasheq 'ok (and (be-unregister! hk) #t) 'accelerator (hotkey->string hk)))
         #:permission 'global-shortcut:unregister
         #:resource (lambda (req) (body-accelerator req)))
   (POST (endpoint "unregister-all")
         (lambda (req) (hasheq 'ok (and (be-unregister-all!) #t)))
         #:permission 'global-shortcut:unregister-all)
   (GET (endpoint "is-registered")
        (lambda (req)
          (define hk (query-hotkey req))
          (hasheq 'registered (and (be-registered? hk) #t) 'accelerator (hotkey->string hk)))
        #:permission 'global-shortcut:is-registered
        #:resource (lambda (req) (query-accelerator req)))))
