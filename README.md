# Glaze

Build desktop apps with a [Racket](https://racket-lang.org/) backend and a web frontend. A [Tauri](https://tauri.app/)-like framework for Racket — write your app logic in Racket, build your UI with HTML/CSS/JS, and ship a desktop application.

![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

## Why Glaze?

Racket's `racket/gui` works but is hard to style into a modern product-grade UI. Glaze takes a different approach: serve a local web app from Racket and display it in the system browser (Phase 1) or an embedded WebView (Phase 3).

You get:

- **Racket for logic** — the full power of Racket's macro system, contracts, pattern matching
- **Web for UI** — Tailwind, Svelte, React, or any web framework
- **JSON API bridge** — Racket macros auto-generate API endpoints

## Requirements

| Dependency | Purpose |
|------------|---------|
| [Racket](https://racket-lang.org/) | 7.0 or later (includes `raco`) |

## Quick Start

### 1. Clone

```bash
git clone https://github.com/turinglambdaai/glaze.git
cd glaze
```

### 2. Install

```bash
raco pkg install glaze
```

### 3. Create a new project

```bash
raco glaze init myapp
cd myapp
```

### 4. Run

```bash
racket main.rkt
```

Your browser opens to `http://127.0.0.1:8080` with a working page.

## CLI Commands

```bash
raco glaze init <name>   # Create a new Glaze project
raco glaze dev           # Start dev server with auto-open browser
raco glaze build         # Build a distributable (exe + bundled assets)
raco glaze help          # Show help
```

### `build`

Package a Glaze project into a platform distribution (`raco exe` + `raco distribute`) with the frontend assets bundled alongside the executable.

```bash
raco glaze build --name myapp              # produces dist/myapp(.exe) + dist/lib + dist/public
raco glaze build --name myapp --installer  # also produce msi / dmg / AppImage (or zip/tar.gz fallback)
```

Options: `--name`, `--icon <.ico/.icns>`, `--entry <path>` (default `main.rkt`), `--out <dir>` (default `dist`), `--embed-dlls` (Windows: single-file exe), `--installer`.

> The installer step probes for the native toolchain (WiX / NSIS on Windows, `create-dmg` / `hdiutil` on macOS, `appimagetool` / `linuxdeploy` on Linux) and **degrades gracefully** to a `.zip` / `.tar.gz` when it's absent, printing a warning naming what to install.

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

## System Tray

Glaze provides a cross-platform system tray so your app can live in the notification area / menu bar with a right-click (or left-click on macOS) menu. The backend is chosen by platform — pure Racket FFI, no native compilation required:

- **Windows** — `Shell_NotifyIconW` via `ffi/unsafe`
- **macOS** — `NSStatusItem` / `NSMenu` via `ffi/unsafe/objc`
- **Linux** — `libayatana-appindicator` + `libgtk-3` via `ffi/unsafe`

If a platform's native libraries aren't available at runtime, the tray silently degrades to a no-op so the rest of the app keeps working.

```racket
(require glaze)

(define t
  (make-tray #:icon #f
             #:tooltip "My Glaze App"
             #:menu (list (make-menu-item "Quit"
                                          #:action (lambda () (exit 0))))))
(tray-set-tooltip! t "running")
;; ...later
(tray-close t)
```

> **macOS note:** a pure menu-bar app (no Dock icon) requires building as an `.app` bundle with `LSUIElement` set — `raco glaze build` configures this for you.

## Roadmap

- [x] **Phase 1** — Local HTTP server + system browser
- [x] **Phase 2** — Frontend asset bundling, system tray, app packaging
- [ ] **Phase 3** — Native WebView embedding (WebView2 / WKWebView / WebKitGTK) — *in progress*

> **Phase 3 status:** the `glaze/webview` module (`open-window` / `open-webview`) is in
> development. The macOS backend (NSWindow + WKWebView via pure Racket objc FFI) is
> verified working end-to-end: window creation, page loads over local HTTP,
> `webview-navigate`, close (programmatic and the red button), and `#:on-close`
> callbacks. Windows has the WebView2 async init chain (environment → controller →
> CoreWebView2) working via pure-Racket COM FFI, but completing `Navigate` is blocked
> on a COM apartment/lifetime issue; until then Windows keeps the stable
> system-browser experience. The Linux (WebKitGTK) backend is scaffolded. Callers
> fall back to `open-browser` when the native backend is unavailable.

## License

Licensed under the [MIT License](LICENSE).
