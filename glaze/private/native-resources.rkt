#lang racket/base

;; Resource and controlled-origin policy shared by every native WebView host.

(require net/uri-codec
         racket/file
         racket/list
         racket/path
         racket/string
         "../capability.rkt")

(provide static-resource
         path->mime-type
         native-scheme-segments
         native-app-origin)

;; ---- shared static resources ----

;; The static file rules both transports serve with: string segments only
;; (".." and "." arrive as path/param symbols and never touch the
;; filesystem), filesystem-level symlink containment, SPA index.html
;; fallback. Returns (values mime-type bytes) or (values #f #f).
(define (static-resource dir segments)
  (cond
    [(not (and (path-string? dir) (directory-exists? dir))) (values #f #f)]
    [(not (andmap string? segments)) (values #f #f)]
    [else
     (define candidate (apply build-path dir segments))
     (cond
       [(and (file-exists? candidate)
             (not (directory-exists? candidate))
             (static-file-contained? dir candidate))
        (values (path->mime-type candidate) (file->bytes candidate))]
       [else
        (define fallback (build-path dir "index.html"))
        (if (and (file-exists? fallback) (static-file-contained? dir fallback))
            (values (path->mime-type fallback) (file->bytes fallback))
            (values #f #f))])]))

;; Filesystem-level containment behind the lexical guard above: a symlink
;; inside public-dir must not smuggle a path outside it. Both sides resolve
;; every symlink component first (e.g. /tmp -> /private/tmp on macOS), so the
;; prefix check compares real locations, not spellings.
(define (static-file-contained? root candidate)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (path-inside? (canonical-path root) (canonical-path candidate))))

(define (path->mime-type p)
  (define ext (path-get-extension p))
  (cond
    [(not ext) #"application/octet-stream"]
    [(member ext '(#".html" #".htm")) #"text/html; charset=utf-8"]
    [(member ext '(#".css")) #"text/css; charset=utf-8"]
    [(member ext '(#".js" #".mjs")) #"application/javascript; charset=utf-8"]
    [(member ext '(#".json")) #"application/json; charset=utf-8"]
    [(member ext '(#".xml")) #"application/xml; charset=utf-8"]
    [(member ext '(#".txt")) #"text/plain; charset=utf-8"]
    [(member ext '(#".svg")) #"image/svg+xml"]
    [(member ext '(#".png")) #"image/png"]
    [(member ext '(#".jpg" #".jpeg")) #"image/jpeg"]
    [(member ext '(#".gif")) #"image/gif"]
    [(member ext '(#".webp")) #"image/webp"]
    [(member ext '(#".avif")) #"image/avif"]
    [(member ext '(#".ico")) #"image/x-icon"]
    [(member ext '(#".woff2")) #"font/woff2"]
    [(member ext '(#".woff")) #"font/woff"]
    [(member ext '(#".ttf")) #"font/ttf"]
    [(member ext '(#".otf")) #"font/otf"]
    [(member ext '(#".wasm")) #"application/wasm"]
    [(member ext '(#".mp4")) #"video/mp4"]
    [(member ext '(#".webm")) #"video/webm"]
    [(member ext '(#".ogg" #".ogv")) #"video/ogg"]
    [(member ext '(#".mp3")) #"audio/mpeg"]
    [(member ext '(#".map")) #"application/json; charset=utf-8"]
    [else #"application/octet-stream"]))

;; ---- scheme URL parsing (shared by every platform's scheme handler) ----

;; "glaze://app/sub/x.js?query#frag" -> '("sub" "x.js"), percent-decoded.
;; The host scheme handlers route on this, so a hostile or malformed URL
;; simply produces #f / non-"glaze" segments and falls to the 404 path.
;; WKWebView/WebKitGTK load the controlled scheme directly
;; (glaze://app/...). WebView2 refuses top-level navigation to custom
;; schemes — the exact reason Tauri uses http://tauri.localhost on
;; Windows — so the Windows host serves http://glaze.localhost/... and the
;; parser accepts both shapes.
(define (native-scheme-segments url-str)
  (define m
    (or (regexp-match #rx"^glaze://app/(.*)$" (or url-str ""))
        (regexp-match #rx"^https?://glaze[.]localhost/(.*)$" (or url-str ""))))
  (and m
       (let* ([rest (second m)]
              [path (car (regexp-split #rx"[?#]" rest))])
         (filter non-empty-string? (map uri-decode (string-split path "/"))))))
;; The origin the page runs on, per platform (for e2e assertions).
(define (native-app-origin)
  (if (eq? (system-type 'os) 'windows) "http://glaze.localhost/" "glaze://app/"))

;; ---- page-side bindings ----
