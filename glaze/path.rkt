#lang racket/base

;; Tauri-style application directories and capability-gated path utilities.

(require racket/file
         racket/list
         racket/path
         racket/string
         "api.rkt"
         "capability.rkt")

(provide path-resolver?
         path-resolver-app-id
         make-path-resolver
         config-dir
         data-dir
         local-data-dir
         cache-dir
         home-dir
         temp-dir
         desktop-dir
         document-dir
         download-dir
         audio-dir
         picture-dir
         video-dir
         public-dir
         template-dir
         font-dir
         runtime-dir
         executable-dir
         resource-dir
         app-config-dir
         app-data-dir
         app-local-data-dir
         app-cache-dir
         app-log-dir
         resolve-resource
         path-join
         path-resolve
         path-normalize
         path-basename
         path-dirname
         path-extname
         path-absolute?
         path-separator
         path-delimiter
         make-path-routes)

(struct path-resolver (app-id resource-root overrides) #:transparent)

(define (complete path [base (current-directory)])
  (simplify-path (path->complete-path path base) #f))

(define (environment-path name fallback)
  (define value (getenv name))
  (if (and value (not (string=? value "")))
      (complete value)
      (complete fallback)))

(define (home-dir)
  (complete (find-system-path 'home-dir)))

(define (temp-dir)
  (complete (find-system-path 'temp-dir)))

(define (config-dir)
  (case (system-type 'os)
    [(windows) (environment-path "APPDATA" (build-path (home-dir) "AppData" "Roaming"))]
    [(macosx) (complete (build-path (home-dir) "Library" "Application Support"))]
    [else (environment-path "XDG_CONFIG_HOME" (build-path (home-dir) ".config"))]))

(define (data-dir)
  (case (system-type 'os)
    [(windows) (config-dir)]
    [(macosx) (config-dir)]
    [else (environment-path "XDG_DATA_HOME" (build-path (home-dir) ".local" "share"))]))

(define (local-data-dir)
  (case (system-type 'os)
    [(windows) (environment-path "LOCALAPPDATA" (build-path (home-dir) "AppData" "Local"))]
    [(macosx) (config-dir)]
    [else (data-dir)]))

(define (cache-dir)
  (case (system-type 'os)
    [(windows) (local-data-dir)]
    [(macosx) (complete (build-path (home-dir) "Library" "Caches"))]
    [else (environment-path "XDG_CACHE_HOME" (build-path (home-dir) ".cache"))]))

(define (xdg-user-directory variable fallback)
  (if (not (eq? (system-type 'os) 'unix))
      (complete fallback)
      (with-handlers ([exn:fail? (lambda (error) (complete fallback))])
        (define file (build-path (config-dir) "user-dirs.dirs"))
        (define matcher (pregexp (format "^~a=\"(.*)\"$" (regexp-quote variable))))
        (define configured
          (and (file-exists? file)
               (for/or ([line (in-list (file->lines file))])
                 (define match (regexp-match matcher (string-trim line)))
                 (and match (second match)))))
        (if configured
            (complete
             (regexp-replace* #px"\\$HOME|\\$\\{HOME\\}" configured (path->string (home-dir)))
             (home-dir))
            (complete fallback)))))

(define (desktop-dir)
  (if (eq? (system-type 'os) 'unix)
      (xdg-user-directory "XDG_DESKTOP_DIR" (build-path (home-dir) "Desktop"))
      (complete (find-system-path 'desk-dir))))

(define (document-dir)
  (if (eq? (system-type 'os) 'unix)
      (xdg-user-directory "XDG_DOCUMENTS_DIR" (build-path (home-dir) "Documents"))
      (complete (find-system-path 'doc-dir))))

(define (download-dir)
  (xdg-user-directory "XDG_DOWNLOAD_DIR" (build-path (home-dir) "Downloads")))

(define (audio-dir)
  (xdg-user-directory "XDG_MUSIC_DIR" (build-path (home-dir) "Music")))

(define (picture-dir)
  (xdg-user-directory "XDG_PICTURES_DIR" (build-path (home-dir) "Pictures")))

(define (video-dir)
  (xdg-user-directory "XDG_VIDEOS_DIR" (build-path (home-dir) "Videos")))

(define (public-dir)
  (xdg-user-directory "XDG_PUBLICSHARE_DIR" (build-path (home-dir) "Public")))

(define (template-dir)
  (xdg-user-directory "XDG_TEMPLATES_DIR" (build-path (home-dir) "Templates")))

(define (font-dir)
  (case (system-type 'os)
    [(windows)
     (define windows-dir
       (environment-path "WINDIR" (build-path (or (getenv "SystemDrive") "C:\\") "Windows")))
     (complete (build-path windows-dir "Fonts"))]
    [(macosx) (complete (build-path (home-dir) "Library" "Fonts"))]
    [else (complete (build-path (data-dir) "fonts"))]))

(define (runtime-dir)
  (and (eq? (system-type 'os) 'unix)
       (let ([value (getenv "XDG_RUNTIME_DIR")])
         (and value (not (string=? value "")) (complete value)))))

(define (executable-dir)
  (complete (or (path-only (find-system-path 'exec-file)) (current-directory))))

(define (default-resource-dir)
  (case (system-type 'os)
    [(macosx)
     (define candidate (complete (build-path (executable-dir) 'up "Resources")))
     (if (directory-exists? candidate)
         candidate
         (executable-dir))]
    [(unix)
     (define app-dir (getenv "APPDIR"))
     (if (and app-dir (not (string=? app-dir "")))
         (complete app-dir)
         (executable-dir))]
    [else (executable-dir)]))

(define app-id-rx #px"^[A-Za-z0-9][A-Za-z0-9._-]*$")

(define (normalize-app-id who app-id)
  (unless (and (string? app-id) (regexp-match? app-id-rx app-id))
    (raise-argument-error
     who
     "application identifier containing letters, digits, dot, underscore, or hyphen"
     app-id))
  app-id)

(define allowed-override-keys '(config data localData cache log))

(define (normalize-overrides value)
  (cond
    [(not value) #f]
    [(path-string? value) value]
    [(hash? value)
     (define result (make-hasheq))
     (for ([(raw-key path) (in-hash value)])
       (define key
         (cond
           [(symbol? raw-key) raw-key]
           [(string? raw-key) (string->symbol raw-key)]
           [else #f]))
       (unless (and (memq key allowed-override-keys) (path-string? path))
         (raise-argument-error 'make-path-resolver
                               "hash with config/data/localData/cache/log path values"
                               value))
       (hash-set! result key path))
     result]
    [else (raise-argument-error 'make-path-resolver "(or/c #f path-string? hash?)" value)]))

(define (make-path-resolver app-id
                            #:resource-root [resource-root (default-resource-dir)]
                            #:app-directories-override [overrides #f])
  (unless (path-string? resource-root)
    (raise-argument-error 'make-path-resolver "path-string?" resource-root))
  (path-resolver (normalize-app-id 'make-path-resolver app-id)
                 (complete resource-root)
                 (normalize-overrides overrides)))

(define (ensure-resolver who resolver)
  (unless (path-resolver? resolver)
    (raise-argument-error who "path-resolver?" resolver)))

(define base-variable-rx #px"^\\$([A-Z]+)(?:[/\\\\](.*))?$")

(define (base-variable-directory name)
  (case (string->symbol name)
    [(AUDIO) (audio-dir)]
    [(CACHE) (cache-dir)]
    [(CONFIG) (config-dir)]
    [(DATA) (data-dir)]
    [(LOCALDATA) (local-data-dir)]
    [(DESKTOP) (desktop-dir)]
    [(DOCUMENT) (document-dir)]
    [(DOWNLOAD) (download-dir)]
    [(HOME) (home-dir)]
    [(PICTURE) (picture-dir)]
    [(PUBLIC) (public-dir)]
    [(TEMP) (temp-dir)]
    [(VIDEO) (video-dir)]
    [else #f]))

(define (resolve-override-path value)
  (define text
    (if (path? value)
        (path->string value)
        value))
  (define match (regexp-match base-variable-rx text))
  (cond
    [match
     (define base (base-variable-directory (second match)))
     (unless base
       (raise-arguments-error 'make-path-resolver "unknown base directory variable" "path" value))
     (if (and (third match) (not (string=? (third match) "")))
         (complete (third match) base)
         base)]
    [(complete-path? value) (complete value)]
    [else (complete value (executable-dir))]))

(define (default-app-directory resolver key)
  (define app-id (path-resolver-app-id resolver))
  (case key
    [(config) (complete (build-path (config-dir) app-id))]
    [(data) (complete (build-path (data-dir) app-id))]
    [(localData) (complete (build-path (local-data-dir) app-id))]
    [(cache) (complete (build-path (cache-dir) app-id))]
    [(log)
     (case (system-type 'os)
       [(macosx) (complete (build-path (home-dir) "Library" "Logs" app-id))]
       [else (complete (build-path (config-dir) app-id "logs"))])]))

(define (app-directory resolver key)
  (ensure-resolver 'app-directory resolver)
  (define overrides (path-resolver-overrides resolver))
  (cond
    [(not overrides) (default-app-directory resolver key)]
    [(path-string? overrides)
     (define root (resolve-override-path overrides))
     (case key
       [(cache) (complete (build-path root "caches"))]
       [(log) (complete (build-path root "logs"))]
       [else root])]
    [(hash-ref overrides key #f)
     =>
     resolve-override-path]
    [else (default-app-directory resolver key)]))

(define (app-config-dir resolver)
  (app-directory resolver 'config))
(define (app-data-dir resolver)
  (app-directory resolver 'data))
(define (app-local-data-dir resolver)
  (app-directory resolver 'localData))
(define (app-cache-dir resolver)
  (app-directory resolver 'cache))
(define (app-log-dir resolver)
  (app-directory resolver 'log))

(define (resource-dir resolver)
  (ensure-resolver 'resource-dir resolver)
  (path-resolver-resource-root resolver))

(define (resolve-resource resolver relative-path)
  (ensure-resolver 'resolve-resource resolver)
  (unless (and (path-string? relative-path) (not (complete-path? relative-path)))
    (raise-argument-error 'resolve-resource "relative path-string?" relative-path))
  (define root (resource-dir resolver))
  (define result (complete relative-path root))
  (define authority
    (make-capability "resource-root" (list (path-permission 'path:resource #:allow (list root)))))
  (unless (capability-authorized? authority 'path:resource result)
    (raise-arguments-error 'resolve-resource "path escapes the resource root" "path" relative-path))
  result)

(define (path-join . paths)
  (unless (and (pair? paths) (andmap path-string? paths))
    (raise-argument-error 'path-join "one or more path strings" paths))
  (simplify-path (apply build-path paths) #f))

(define (path-resolve . paths)
  (unless (and (pair? paths) (andmap path-string? paths))
    (raise-argument-error 'path-resolve "one or more path strings" paths))
  (for/fold ([result (current-directory)]) ([path (in-list paths)])
    (if (complete-path? path)
        (complete path)
        (complete path result))))

(define (path-normalize path)
  (unless (path-string? path)
    (raise-argument-error 'path-normalize "path-string?" path))
  (simplify-path path #f))

(define (path-basename path)
  (unless (path-string? path)
    (raise-argument-error 'path-basename "path-string?" path))
  (define name (file-name-from-path (path-normalize path)))
  (if name
      (path->string name)
      ""))

(define (path-dirname path)
  (unless (path-string? path)
    (raise-argument-error 'path-dirname "path-string?" path))
  (define directory (or (path-only (path-normalize path)) (string->path ".")))
  (path->string (apply build-path (explode-path directory))))

(define (path-extname path)
  (unless (path-string? path)
    (raise-argument-error 'path-extname "path-string?" path))
  (define extension (path-get-extension path))
  (if extension
      (bytes->string/utf-8 extension)
      ""))

(define (path-absolute? path)
  (unless (path-string? path)
    (raise-argument-error 'path-absolute? "path-string?" path))
  (complete-path? path))

(define path-separator (if (eq? (system-type 'os) 'windows) "\\" "/"))
(define path-delimiter (if (eq? (system-type 'os) 'windows) ";" ":"))

(define missing (gensym 'missing))

(define (bad-parameter message)
  (raise (exn:fail:glaze:bad-param message (current-continuation-marks))))

(define (body-hash req)
  (define body (request-json-body req))
  (unless (hash? body)
    (bad-parameter "body: expected a JSON object"))
  body)

(define (frontend-path? value)
  (and (string? value) (<= (string-length value) 32768)))

(define (body-ref body key predicate)
  (define value (hash-ref body key missing))
  (cond
    [(eq? value missing) (bad-parameter (format "~a: missing" key))]
    [(predicate value) value]
    [else (bad-parameter (format "~a: invalid value ~v" key value))]))

(define (path-list? value)
  (and (list? value)
       (<= 1 (length value) 128)
       (andmap frontend-path? value)
       (<= (for/sum ([path (in-list value)]) (string-length path)) 65536)))

(define (make-path-routes #:app-id app-id
                          #:resource-root [resource-root (default-resource-dir)]
                          #:app-directories-override [overrides #f]
                          #:prefix [prefix "api/path"])
  (unless (and (string? prefix) (not (string=? prefix "")))
    (raise-argument-error 'make-path-routes "non-empty-string?" prefix))
  (define resolver
    (make-path-resolver app-id #:resource-root resource-root #:app-directories-override overrides))
  (define (endpoint name)
    (string-append (string-trim prefix "/") "/" name))
  (define directory-specs
    (list (list "app-config-dir" 'path:app-config (lambda () (app-config-dir resolver)))
          (list "app-data-dir" 'path:app-data (lambda () (app-data-dir resolver)))
          (list "app-local-data-dir" 'path:app-local-data (lambda () (app-local-data-dir resolver)))
          (list "app-cache-dir" 'path:app-cache (lambda () (app-cache-dir resolver)))
          (list "app-log-dir" 'path:app-log (lambda () (app-log-dir resolver)))
          (list "config-dir" 'path:config config-dir)
          (list "data-dir" 'path:data data-dir)
          (list "local-data-dir" 'path:local-data local-data-dir)
          (list "cache-dir" 'path:cache cache-dir)
          (list "home-dir" 'path:home home-dir)
          (list "temp-dir" 'path:temp temp-dir)
          (list "desktop-dir" 'path:desktop desktop-dir)
          (list "document-dir" 'path:document document-dir)
          (list "download-dir" 'path:download download-dir)
          (list "audio-dir" 'path:audio audio-dir)
          (list "picture-dir" 'path:picture picture-dir)
          (list "video-dir" 'path:video video-dir)
          (list "public-dir" 'path:public public-dir)
          (list "template-dir" 'path:template template-dir)
          (list "font-dir" 'path:font font-dir)
          (list "runtime-dir" 'path:runtime runtime-dir)
          (list "executable-dir" 'path:executable executable-dir)
          (list "resource-dir" 'path:resource (lambda () (resource-dir resolver)))))
  (append
   (for/list ([spec (in-list directory-specs)])
     (GET (endpoint (first spec))
          (lambda (req)
            (define path ((third spec)))
            (hasheq 'path (and path (path->string path))))
          #:permission (second spec)
          #:resource (lambda (req) ((third spec)))))
   (list
    (POST (endpoint "resolve-resource")
          (lambda (req)
            (hasheq 'path
                    (path->string
                     (resolve-resource resolver (body-ref (body-hash req) 'path frontend-path?)))))
          #:permission 'path:resource
          #:resource (lambda (req)
                       (resolve-resource resolver (body-ref (body-hash req) 'path frontend-path?))))
    (POST (endpoint "join")
          (lambda (req)
            (hasheq 'path
                    (path->string (apply path-join (body-ref (body-hash req) 'paths path-list?)))))
          #:permission 'path:join)
    (POST (endpoint "resolve")
          (lambda (req)
            (hasheq 'path
                    (path->string (apply path-resolve (body-ref (body-hash req) 'paths path-list?)))))
          #:permission 'path:resolve)
    (POST (endpoint "normalize")
          (lambda (req)
            (hasheq 'path
                    (path->string (path-normalize (body-ref (body-hash req) 'path frontend-path?)))))
          #:permission 'path:normalize)
    (POST (endpoint "basename")
          (lambda (req)
            (hasheq 'path (path-basename (body-ref (body-hash req) 'path frontend-path?))))
          #:permission 'path:basename)
    (POST (endpoint "dirname")
          (lambda (req) (hasheq 'path (path-dirname (body-ref (body-hash req) 'path frontend-path?))))
          #:permission 'path:dirname)
    (POST (endpoint "extname")
          (lambda (req)
            (hasheq 'extension (path-extname (body-ref (body-hash req) 'path frontend-path?))))
          #:permission 'path:extname)
    (POST (endpoint "is-absolute")
          (lambda (req)
            (hasheq 'absolute (path-absolute? (body-ref (body-hash req) 'path frontend-path?))))
          #:permission 'path:is-absolute)
    (GET (endpoint "separator")
         (lambda (req) (hasheq 'separator path-separator))
         #:permission 'path:separator)
    (GET (endpoint "delimiter")
         (lambda (req) (hasheq 'delimiter path-delimiter))
         #:permission 'path:delimiter))))
