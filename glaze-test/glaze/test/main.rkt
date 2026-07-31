#lang racket/base

(require rackunit
         glaze/server
         glaze/browser
         glaze/assets
         racket/file
         racket/port
         racket/string
         net/http-client
         net/url)

;; ---- Server API smoke tests ----
(check-equal? (procedure? start-dev-server) #t "start-dev-server is a procedure")
(check-equal? (procedure? start-server) #t "start-server is a procedure")
(check-equal? (procedure? stop-server) #t "stop-server is a procedure")
(check-equal? (eq? start-dev-server start-server) #t "start-dev-server aliases start-server")

;; ---- MIME table tests ----
(check-equal? (path->mime-type "index.html") #"text/html; charset=utf-8")
(check-equal? (path->mime-type "app.js") #"application/javascript; charset=utf-8")
(check-equal? (path->mime-type "app.mjs") #"application/javascript; charset=utf-8")
(check-equal? (path->mime-type "style.css") #"text/css; charset=utf-8")
(check-equal? (path->mime-type "data.json") #"application/json; charset=utf-8")
(check-equal? (path->mime-type "logo.svg") #"image/svg+xml")
(check-equal? (path->mime-type "photo.webp") #"image/webp")
(check-equal? (path->mime-type "anim.avif") #"image/avif")
(check-equal? (path->mime-type "font.woff2") #"font/woff2")
(check-equal? (path->mime-type "module.wasm") #"application/wasm")
(check-equal? (path->mime-type "clip.mp4") #"video/mp4")
(check-equal? (path->mime-type "noext") #"application/octet-stream")

;; ---- resolve-public-dir ----
(check-true (complete-path? (resolve-public-dir "/abs/path")) "absolute path stays complete")
(check-true (complete-path? (resolve-public-dir "public")) "relative path becomes complete")

;; ---- assets tests ----
(define tmp-dir (make-temporary-file "glaze-test-~a" 'directory))
(check-not-exn (lambda () (ensure-public-dir tmp-dir)) "ensure-public-dir creates dir")
(check-true (directory-exists? tmp-dir) "public dir exists")
(delete-directory/files tmp-dir)

;; ---- end-to-end HTTP serving ----
(define e2e-dir (make-temporary-file "glaze-e2e-~a" 'directory))
(call-with-output-file (build-path e2e-dir "index.html")
  (lambda (out) (display #"<!DOCTYPE html><html><body>hello glaze</body></html>" out))
  #:exists 'replace)
(call-with-output-file (build-path e2e-dir "app.js")
  (lambda (out) (display #"console.log(1)" out))
  #:exists 'replace)

;; fixed port avoids the port-0 surface issue in the underlying web-server
(define port 18923)
(define-values (served-port shutdown) (start-server #:port port #:public-dir e2e-dir))
(check-equal? served-port port "server returns requested port")

(define (get path-str)
  (define-values (status-line headers in)
    (http-sendrecv "127.0.0.1" path-str #:port port #:ssl? #f))
  (define body (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status-line) headers body))

;; root serves index.html
(let-values ([(status headers body) (get "/")])
  (check-true (string-contains? status "200") "GET / returns 200")
  (check-true (regexp-match? #rx#"hello glaze" body) "GET / returns index body"))

;; explicit file with correct body
(let-values ([(status headers body) (get "/app.js")])
  (check-true (string-contains? status "200") "GET /app.js returns 200")
  (check-true (regexp-match? #rx#"console.log" body) "GET /app.js returns file body"))

;; missing path falls back to index.html (SPA behavior)
(let-values ([(status headers body) (get "/no-such-file")])
  (check-true (string-contains? status "200") "missing path falls back to index (200)")
  (check-true (regexp-match? #rx#"hello glaze" body) "fallback serves index body"))

(shutdown)
(delete-directory/files e2e-dir)

;; ---- Browser tests ----
(check-equal? (procedure? open-browser) #t "open-browser is a procedure")

;; ---- Tray protocol tests (platform-agnostic) ----
(require glaze/tray/tray-protocol)

(define mi1 (make-menu-item "Quit" #:action (lambda () 'quit)))
(check-equal? (menu-item-label mi1) "Quit")
(check-equal? (menu-item-id mi1) "Quit")
(check-equal? ((menu-item-action mi1)) 'quit)
(check-true (menu-item? mi1))

(define sep (menu-separator))
(check-true (menu-separator? sep))
(check-false (menu-item-label sep))

;; id-allocator: increasing ids, lookup, clear.
(define alloc (make-id-allocator))
(define a1 (id-allocator-register! alloc (lambda () 'one)))
(define a2 (id-allocator-register! alloc (lambda () 'two)))
(check-true (< a1 a2) "ids strictly increase")
(check-equal? ((id-allocator-lookup alloc a1)) 'one)
(check-equal? ((id-allocator-lookup alloc a2)) 'two)
(check-false (id-allocator-lookup alloc 99999) "unknown id -> #f")
(id-allocator-clear! alloc)
(check-false (id-allocator-lookup alloc a1) "cleared -> #f")

;; ---- Tray public API tests ----
(require glaze/tray/main)

(check-equal? (procedure? make-tray) #t "make-tray is a procedure")
(check-equal? (procedure? tray-set-tooltip!) #t)
(check-equal? (procedure? tray-set-icon!) #t)
(check-equal? (procedure? tray-set-menu!) #t)
(check-equal? (procedure? tray-close) #t)

;; make-tray must always return a tray? handle, on every platform: native
;; backends on supported hosts, stub fallback elsewhere. The result must be
;; usable without raising.
(define t (make-tray #:icon #f
                     #:tooltip "Glaze Test"
                     #:menu (list (make-menu-item "Quit" #:action (lambda () (void)))
                                  (menu-separator)
                                  (make-menu-item "Hi" #:action (lambda () (void))))))
(check-true (tray? t) "make-tray returns a tray?")
(check-not-false (memq (tray-backend t) '(windows macos linux stub)) "valid backend tag")
(check-not-exn (lambda () (tray-set-tooltip! t "updated")) "set-tooltip! does not raise")
(check-not-exn (lambda () (tray-set-menu! t (list (make-menu-item "Only" #:action void)))) "set-menu! does not raise")
(check-not-exn (lambda () (tray-close t)) "close does not raise")

;; ---- Windows backend end-to-end (only on 'windows) ----
(when (eq? (system-type 'os) 'windows)
  ;; Use dynamic-require since `require` must be at module level; this keeps
  ;; the test gated to the host OS.
  (define mod-make-tray (dynamic-require 'glaze/tray/tray-windows 'make-tray))
  (define mod-supported? (dynamic-require 'glaze/tray/tray-windows 'supported?))
  (define mod-win:tray? (dynamic-require 'glaze/tray/tray-windows 'win:tray?))
  (define mod-set-tooltip! (dynamic-require 'glaze/tray/tray-windows 'set-tooltip!))
  (define mod-set-menu! (dynamic-require 'glaze/tray/tray-windows 'set-menu!))
  (define mod-close (dynamic-require 'glaze/tray/tray-windows 'close))
  (check-true (mod-supported?) "Windows backend reports supported")
  (define wt (mod-make-tray #:icon #f
                            #:tooltip "Direct backend test"
                            #:menu (list (make-menu-item "Quit" #:action (lambda () (void))))))
  (check-true (mod-win:tray? wt) "direct Windows backend returns win:tray?")
  (check-not-exn (lambda () (mod-set-tooltip! wt "x")))
  (check-not-exn (lambda () (mod-set-menu! wt '())))
  (check-not-exn (lambda () (mod-close wt)) "direct backend close does not raise"))
