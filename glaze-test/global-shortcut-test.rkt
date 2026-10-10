#lang racket/base

(require json
         net/http-client
         net/uri-codec
         net/url
         racket/file
         racket/list
         racket/port
         racket/string
         rackunit
         glaze/capability
         glaze/events
         glaze/global-shortcut
         glaze/hotkey/main
         glaze/server)

;; ---- accelerator parsing ----

(define cmd-mod (if (eq? (system-type 'os) 'macosx) "Cmd" "Ctrl"))

(check-equal? (hotkey->string (string->hotkey "CmdOrCtrl+Shift+D"))
              (string-append cmd-mod "+Shift+D"))
(check-equal? (hotkey->string (string->hotkey "  COMMANDORCONTROL+SHIFT+d  "))
              (string-append cmd-mod "+Shift+D"))
(check-equal? (hotkey->string (string->hotkey "KeyD")) "D")
(check-equal? (hotkey->string (string->hotkey "Ctrl+KeyD")) "Ctrl+D")
(check-equal? (hotkey->string (string->hotkey "ctrl+d")) "Ctrl+D")
(check-equal? (hotkey->string (string->hotkey "Digit7")) "7")
(check-equal? (hotkey->string (string->hotkey "9")) "9")
(check-equal? (hotkey->string (string->hotkey "Shift+Ctrl+D"))
              "Ctrl+Shift+D"
              "modifiers canonicalize to cmd,ctrl,alt,shift order")
(check-equal? (hotkey->string (string->hotkey "Ctrl+Ctrl+D")) "Ctrl+D" "duplicate modifiers collapse")
(check-equal? (hotkey->string (string->hotkey "Alt+Space")) "Alt+Space")
(check-equal? (hotkey->string (string->hotkey "Cmd+F24")) "Cmd+F24")
(check-equal? (hotkey->string (string->hotkey "Super+Comma")) "Cmd+Comma")
(check-equal? (hotkey->string (string->hotkey "Option+Comma")) "Alt+Comma")
(check-equal? (hotkey->string (string->hotkey "Ctrl+Numpad7")) "Ctrl+Numpad7")
(check-equal? (hotkey->string (string->hotkey "Ctrl+PageDown")) "Ctrl+PageDown")
(check-equal? (hotkey->string (string->hotkey "D")) "D" "bare keys are allowed")
(check-equal? (hotkey->string (string->hotkey "Meta+BracketLeft")) "Cmd+BracketLeft")

(check-false (string->hotkey "") "empty is invalid")
(check-false (string->hotkey "+") "lone plus is invalid")
(check-false (string->hotkey "Ctrl+") "trailing plus is invalid")
(check-false (string->hotkey "+D") "leading plus is invalid")
(check-false (string->hotkey "Pizza+D") "unknown modifier is invalid")
(check-false (string->hotkey "Ctrl+Pizza") "unknown key is invalid")
(check-false (string->hotkey "D++") "empty part is invalid")
(check-false (string->hotkey "F25") "F25 does not exist")
(check-false (string->hotkey "F0") "F0 does not exist")
(check-false (string->hotkey "Ctrl+NumpadEqual") "unknown numpad key is invalid")
(check-false (string->hotkey 5) "non-strings are invalid")
(check-true (accelerator? "Ctrl+D"))
(check-false (accelerator? "Ctrl+"))

;; round trip is idempotent
(check-equal? (hotkey->string (string->hotkey (hotkey->string (string->hotkey "cmdorctrl+alt+f5"))))
              (string-append cmd-mod "+Alt+F5"))

(check-exn exn:fail? (lambda () (make-hotkey '(pizza) 'D)) "unknown modifier rejected")
(check-exn exn:fail? (lambda () (make-hotkey '(ctrl) 'Pizza)) "unknown key rejected")
(check-equal? (hotkey->string (make-hotkey '(shift ctrl shift) 'D)) "Ctrl+Shift+D")

;; ---- accelerator-permission scopes ----

(define (scope-authorized? scope resource)
  (capability-authorized? (make-capability "scope-test" (list scope))
                          'global-shortcut:register
                          resource))

(define register-scope
  (accelerator-permission 'global-shortcut:register
                          #:allow '("CmdOrCtrl+Shift+D" "Ctrl+F5")
                          #:deny '("Ctrl+F5")))
(check-true (scope-authorized? register-scope "COMMANDORCONTROL+shift+d")
            "scope matches case variants")
(check-true (scope-authorized? register-scope "CommandOrControl+Shift+KeyD"))
(check-false (scope-authorized? register-scope "Ctrl+F5") "deny takes precedence")
(check-false (scope-authorized? register-scope "Ctrl+F9") "out of scope is denied")
(check-false (scope-authorized? register-scope "Ctrl+") "unparseable is denied")
(check-false (scope-authorized? register-scope 7) "non-strings are denied")

(define regex-scope
  (accelerator-permission 'global-shortcut:register #:allow (list #rx"^Ctrl\\+F[0-9]$")))
(check-true (scope-authorized? regex-scope "CTRL+F5") "regexps match the canonical form")
(check-false (scope-authorized? regex-scope "Ctrl+F25") "F25 never parses, so it cannot match")

(check-exn exn:fail?
           (lambda () (accelerator-permission 'x #:allow '("Nope+D")))
           "unparseable allow patterns fail at construction")
(check-exn exn:fail?
           (lambda () (accelerator-permission 'x #:allow '("D") #:deny '("Junk")))
           "unparseable deny patterns fail at construction")

;; ---- fake backend + routes ----

(define fake-registered (make-hash)) ; (list mods key) -> thunk
(define (fake-k hk)
  (list (hotkey-mods hk) (hotkey-key hk)))
(define fake-backend
  (make-hotkey-backend (lambda () #t)
                       (lambda (hk thunk)
                         (hash-set! fake-registered (fake-k hk) thunk)
                         #t)
                       (lambda (hk)
                         (if (hash-has-key? fake-registered (fake-k hk))
                             (begin
                               (hash-remove! fake-registered (fake-k hk))
                               #t)
                             #f))
                       (lambda ()
                         (hash-clear! fake-registered)
                         #t)
                       (lambda (hk) (hash-has-key? fake-registered (fake-k hk)))))

(define bus (make-event-bus))
(define bus-ch (bus-subscribe! bus))

(define root (make-temporary-file "glaze-global-shortcut-~a" 'directory))
(define authority
  (make-capability
   "main"
   (list (accelerator-permission 'global-shortcut:register #:allow '("CmdOrCtrl+Shift+D"))
         (accelerator-permission 'global-shortcut:unregister #:allow '("CmdOrCtrl+Shift+D"))
         (accelerator-permission 'global-shortcut:is-registered #:allow '("CmdOrCtrl+Shift+D"))
         'global-shortcut:unregister-all
         'glaze:events)))
(define token "global-shortcut-token")
(define port 18982)
(define-values (_port shutdown)
  (start-server #:port port
                #:public-dir root
                #:api-token token
                #:capability authority
                #:events bus
                #:api (make-global-shortcut-routes #:backend fake-backend #:events bus)))

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

;; register within scope
(let-values ([(status body) (call "POST"
                                  "/api/global-shortcut/register"
                                  (hasheq 'accelerator "CmdOrCtrl+Shift+D"))])
  (check-true (string-contains? status "200"))
  (define result (bytes->jsexpr body))
  (check-true (hash-ref result 'ok))
  (check-equal? (hash-ref result 'accelerator) (string-append cmd-mod "+Shift+D"))
  (check-false (hash-ref result 'alreadyRegistered)))

;; triggering the registered hotkey pushes the SSE event
(define thunk (hash-ref fake-registered (fake-k (string->hotkey "CmdOrCtrl+Shift+D"))))
(thunk)
(define event (bus-wait bus-ch 5))
(check-not-eq? event 'timeout "trigger broadcasts the event")
(check-equal? (second event) 'global-shortcut)
(check-equal? (hash-ref (third event) 'accelerator) (string-append cmd-mod "+Shift+D"))

;; idempotent re-register reports alreadyRegistered
(let-values ([(status body) (call "POST"
                                  "/api/global-shortcut/register"
                                  (hasheq 'accelerator "cmdorctrl+shift+D"))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref (bytes->jsexpr body) 'alreadyRegistered)))

;; is-registered round trip (query parameter)
(let-values ([(_status body) (call "GET"
                                   (string-append "/api/global-shortcut/is-registered?accelerator="
                                                  (form-urlencoded-encode "CmdOrCtrl+Shift+D")))])
  (check-true (hash-ref (bytes->jsexpr body) 'registered)))
(let-values ([(status body) (call "GET"
                                  (string-append "/api/global-shortcut/is-registered?accelerator="
                                                 (form-urlencoded-encode "Ctrl+F9")))])
  (check-true (string-contains? status "403") "out-of-scope query is denied"))

;; unregister (CmdOrCtrl spelling: the registered hotkey is cmd on macOS)
(let-values ([(status body) (call "POST"
                                  "/api/global-shortcut/unregister"
                                  (hasheq 'accelerator "CmdOrCtrl+Shift+D"))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref (bytes->jsexpr body) 'ok)))
(let-values ([(_status body) (call "GET"
                                   (string-append "/api/global-shortcut/is-registered?accelerator="
                                                  (form-urlencoded-encode "CmdOrCtrl+Shift+D")))])
  (check-false (hash-ref (bytes->jsexpr body) 'registered)))

;; permission denials
(let-values ([(status _)
              (call "POST" "/api/global-shortcut/register" (hasheq 'accelerator "Ctrl+F9"))])
  (check-true (string-contains? status "403") "out-of-scope registration is denied"))
(let-values ([(status _)
              (call "POST" "/api/global-shortcut/register" (hasheq 'accelerator "Nope+D"))])
  (check-true (string-contains? status "403") "unparseable accelerators are denied"))
(let-values
    ([(status _)
      (call "POST" "/api/global-shortcut/register" (hasheq 'accelerator "Ctrl+Shift+D") #:token? #f)])
  (check-true (string-contains? status "401") "token is required"))

;; generated client surfaces only authorized routes
(let-values ([(_status body) (call "GET" "/glaze/api.js" #f #:token? #f)])
  (define js (bytes->string/utf-8 body))
  (check-true (string-contains? js "globalShortcutRegister"))
  (check-true (string-contains? js "globalShortcutUnregisterAll"))
  (check-true (string-contains? js "globalShortcutIsRegistered")))

(shutdown)

;; open routes: validation without a capability still maps bad input to 400
(define port2 18983)
(define-values (_port2 shutdown2)
  (start-server #:port port2
                #:public-dir root
                #:api (make-global-shortcut-routes #:backend fake-backend)))
(define (call2 method path [body #f])
  (define data (and body (string->bytes/utf-8 (jsexpr->string body))))
  (define-values (status headers in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port port2
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers (if data
                                 '("Content-Type: application/json")
                                 '())))
  (define response-bytes (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status) response-bytes))

(let-values ([(status _body)
              (call2 "POST" "/api/global-shortcut/register" (hasheq 'accelerator "Pizza+D"))])
  (check-true (string-contains? status "400") "invalid accelerators are a client error"))
(let-values ([(status _body) (call2 "POST" "/api/global-shortcut/register" (hasheq 'nope 1))])
  (check-true (string-contains? status "400") "missing accelerator is a client error"))
(let-values ([(status body)
              (call2 "POST" "/api/global-shortcut/register" (hasheq 'accelerator "Ctrl+F5"))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref (bytes->jsexpr body) 'ok)))
(let-values ([(status body) (call2 "POST" "/api/global-shortcut/unregister-all" (hasheq))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref (bytes->jsexpr body) 'ok)))
(check-false (hash-has-key? fake-registered (fake-k (string->hotkey "Ctrl+F5")))
             "unregister-all clears the backend")

(shutdown2)
(delete-directory/files root)

;; ---- real backend lifecycle (gated on platform support) ----

(when (hotkey-supported?)
  ;; A three-modifier combo avoids conflicts with real user shortcuts.
  (define hk (make-hotkey '(ctrl alt shift) 'K))
  (define thunk-count (box 0))
  (define registered?
    (hotkey-register! hk (lambda () (set-box! thunk-count (add1 (unbox thunk-count))))))
  (check-true (boolean? registered?))
  (when registered?
    (check-true (hotkey-registered? hk))
    (check-false (hotkey-register! hk void) "duplicate registration fails")
    (check-true (hotkey-unregister! hk))
    (check-false (hotkey-registered? hk))
    (check-false (hotkey-unregister! hk) "unregistering twice reports false"))
  ;; sweep semantics
  (define hk2 (make-hotkey '(ctrl alt shift) 'J))
  (when (hotkey-register! hk2 void)
    (check-true (hotkey-unregister-all!))
    (check-false (hotkey-registered? hk2))))
