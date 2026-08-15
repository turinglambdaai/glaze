# Glaze

Build desktop apps with a [Racket](https://racket-lang.org/) backend and a web frontend. A [Tauri](https://tauri.app/)-like framework for Racket — write your app logic in Racket, build your UI with HTML/CSS/JS, and ship a desktop application.

![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

## Why Glaze?

Racket's `racket/gui` works but is hard to style into a modern product-grade UI. Glaze takes a different approach: serve a local web app from Racket and display it in the system browser (Phase 1) or an embedded WebView (Phase 3).

You get:

- **Racket for logic** — the full power of Racket's macro system, contracts, pattern matching
- **Web for UI** — Tailwind, Svelte, React, or any web framework
- **JSON API bridge** — the page calls Racket with plain `fetch("/api/...")`

### How it compares

| | Glaze | Tauri | Electron | wails |
|---|---|---|---|---|
| Backend language | Racket | Rust | JS/Node | Go |
| Native toolchain needed | **none** (pure FFI) | Rust + cargo | none | Go + WebView2 deps |
| Binary size | tiny (Racket exe + assets) | small | 100 MB+ | small |
| Frontend→backend | HTTP JSON routes (`fetch`) | `invoke()` IPC | Node APIs | bindings |
| Works without webview (browser fallback) | **yes** | no | no | no |
| Agent-friendly UI verification (`title`/`url`/screenshot) | **built-in** | via WebDriver | via CDP | limited |
| WebView backends | WebView2 / WKWebView / WebKitGTK | same | bundled Chromium | WebView2/WKWebView |

All three webview backends pass the real-window CI e2e (open, load, capture, navigate, close, on-close). Remaining honest gaps: no typed IPC layer (plain JSON), Linux needs a desktop session or Xvfb.

## Platform status

| Capability | macOS | Windows | Linux |
|---|---|---|---|
| HTTP server + browser | ✅ | ✅ | ✅ |
| System tray | ✅ | ✅ | ✅ (CI-verified) |
| JSON API bridge | ✅ | ✅ | ✅ |
| Native webview window | ✅ verified end-to-end | ✅ CI e2e (WebView2) | ✅ CI e2e (Xvfb + WebKitGTK) |
| `webview-title` / `webview-url` | ✅ | ✅ | ✅ |
| `webview-capture!` (screenshot) | ✅ | ✅ (PrintWindow + PowerShell PNG) | ✅ (gdk_pixbuf) |
| `#:devtools?` | ✅ (inspectable, macOS 13+) | ✅ (`OpenDevToolsWindow`) | 🔲 |

Without a native backend, `run-app` / `open-window` automatically fall back to the system browser — the app still works everywhere.

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

### `run-app`

The one-call entry: picks a free port, starts the server (static + JSON API), opens the native webview window, and blocks until the window closes.

```racket
(run-app #:public-dir "public"
         #:api (list (GET "api/ping" ...)))
;; webview path: window closed -> server stopped -> (values 'webview shutdown)
;; browser fallback (no native backend): opens browser -> (values 'browser shutdown)
```

### `start-server` / `start-dev-server`

Starts a local HTTP server serving static files with SPA fallback, plus optional JSON API routes. `start-dev-server` is a backward-compatible alias.

```racket
(start-server #:port 8080
              #:public-dir "public"
              #:api (list (GET "api/ping" (lambda (req) (hasheq 'pong #t)))))
;; Returns (values port shutdown-proc); verifies the listener is accepting
;; before returning.
```

### `stop-server`

Stops the server.

```racket
(stop-server shutdown-proc)
```

### `open-browser`

Opens a URL in the system default browser (cross-platform: Windows, macOS, Linux).

```racket
(open-browser "http://127.0.0.1:8080")
```

## JavaScript Bridge

The frontend calls Racket with plain `fetch("/api/...")` — Glaze's answer to Tauri's `invoke()`. One code path works in the embedded WebView, in the system-browser fallback, and in dev (curl-able). Routes are ordinary values:

```racket
(require glaze)

(GET  "api/ping"            (lambda (req) (hasheq 'pong #t)))
(POST "api/items/:id/bump"  (lambda (req id) (hasheq 'id id 'bumped #t)))
(POST "api/echo"            (lambda (req)
                              (define body (request-json-body req))
                              (hasheq 'echo body)))
```

- Handlers take the request plus captured `:params`; return a jsexpr (auto-wrapped as JSON 200) or a full response.
- `request-json-body` parses the JSON body — note Racket jsexpr parses JSON object keys as **symbols** (`(hash-ref body 'delta)`).
- A handler that raises becomes a 500 JSON error, never a broken connection.
- Unmatched requests fall through to static files (SPA `index.html` fallback).

In the page:

```js
const s = await fetch('/api/counter/bump',
  {method:'POST', headers:{'Content-Type':'application/json'},
   body: JSON.stringify({delta: 5})}).then(r => r.json());
```

See [`examples/counter/`](examples/counter/) for the complete working app.

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

## Examples

| Example | What it shows |
|---|---|
| [`examples/hello/`](examples/hello/) | Minimal app — `run-app` in 8 lines |
| [`examples/counter/`](examples/counter/) | JS↔Racket bridge — `fetch` calls Racket state |
| [`examples/webview-demo.rkt`](examples/webview-demo.rkt) | Webview lifecycle: load, navigate, close, verification APIs |
| [`examples/agent-verify.rkt`](examples/agent-verify.rkt) | Agent workflow: assert page state + screenshot with no human |
| [`examples/tray-demo.rkt`](examples/tray-demo.rkt) | Cross-platform system tray with a working menu |

## Roadmap

- [x] **Phase 1** — Local HTTP server + system browser
- [x] **Phase 2** — Frontend asset bundling, system tray, app packaging
- [x] **Phase 3** — Native WebView embedding (WebView2 / WKWebView / WebKitGTK) — *done, verified by the 3-OS CI e2e*

> **Phase 3 done:** all three backends (macOS WKWebView, Windows WebView2, Linux
> WebKitGTK) pass the real-window CI e2e — open, page load, `webview-title`/`url`
> verification, `webview-capture!` screenshots, `webview-navigate`, close (programmatic
> and OS chrome), and `#:on-close` callbacks; `#:devtools?` on macOS/Windows. Pure
> Racket FFI throughout, no compiler. Remaining polish (not blockers): Linux
> `#:devtools?`, Windows resize-follow (`put_Bounds` is set once, not on WM_SIZE),
> multi-window ergonomics.

## License

Licensed under the [MIT License](LICENSE).
