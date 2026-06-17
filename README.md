# Glaze

![Language](https://img.shields.io/badge/language-Racket-red) [![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)  [![English](https://img.shields.io/badge/lang-English-blue)](README.md) [![中文](https://img.shields.io/badge/lang-中文-red)](README.zh-CN.md)


Build desktop apps with a [Racket](https://racket-lang.org/) backend and a web frontend. A [Tauri](https://tauri.app/)-like framework for Racket -- write your app logic in Racket, build your UI with HTML/CSS/JS, and ship a desktop application.

## Why Glaze?

Racket's `racket/gui` works but is hard to style into a modern product-grade UI. Glaze takes a different approach: serve a local web app from Racket and display it in the system browser (Phase 1) or an embedded WebView (Phase 3).

You get:

- **Racket for logic** -- the full power of Racket's macro system, contracts, pattern matching
- **Web for UI** -- Tailwind, Svelte, React, or any web framework
- **JSON API bridge** -- Racket macros auto-generate API endpoints

## Quick Start

```bash
# Install
raco pkg install glaze

# Create a new project
raco glaze init myapp
cd myapp

# Run
racket main.rkt
```

Your browser opens to `http://127.0.0.1:8080` with a working page.

## CLI Commands

```bash
raco glaze init <name>   # Create a new Glaze project
raco glaze dev           # Start dev server with auto-open browser
raco glaze help          # Show help
```

## Project Structure

A new Glaze project looks like this:

```
myapp/
├── main.rkt          # Racket entry point
└── public/
    └── index.html    # Frontend
```

`main.rkt` starts a local HTTP server serving files from `public/` and opens the browser:

```racket
#lang racket/base

(require glaze)

(define-values (port server)
  (start-dev-server #:public-dir "public"))

(printf "Glaze app running at http://127.0.0.1:~a\n" port)
(open-browser (format "http://127.0.0.1:~a" port))

(with-handlers ([exn:break?
                 (lambda (e)
                   (stop-server server)
                   (printf "Server stopped.\n"))])
  (sync never-evt))
```

## Monorepo Structure

```
glaze/
├── glaze-lib/        # Core library (server, API, browser launcher, assets)
├── glaze-cli/        # CLI tool (raco glaze init / dev)
├── glaze-doc/        # Documentation (Scribble)
├── glaze-test/       # Tests
└── info.rkt          # Multi-package root
```

## API

### `start-dev-server`

Starts a local HTTP server that serves static files from a directory.

```racket
(start-dev-server #:port 8080 #:public-dir "public")
;; Returns (values port shutdown-proc)
```

### `stop-server`

Stops the dev server.

```racket
(stop-server shutdown-proc)
```

### `open-browser`

Opens a URL in the system default browser (cross-platform: Windows, macOS, Linux).

```racket
(open-browser "http://127.0.0.1:8080")
```

### `define-api`

Macro for defining JSON API endpoints.

```racket
(define-api (my-handler request)
  (json-response (hasheq 'status "ok")))
```

## Roadmap

- [x] **Phase 1** -- Local HTTP server + system browser
- [ ] **Phase 2** -- Frontend asset bundling, system tray, app packaging
- [ ] **Phase 3** -- Native WebView embedding (WebView2 / WKWebView / WebKitGTK)

## License

[MIT](LICENSE)
