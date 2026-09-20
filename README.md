# Glaze

Build desktop apps with a [Racket](https://racket-lang.org/) backend and a web frontend. A [Tauri](https://tauri.app/)-like framework for Racket — write your app logic in Racket, build your UI with HTML/CSS/JS, and ship a desktop application.

[![CI](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![Release](https://img.shields.io/badge/release-0.7.0-C15F3C)](CHANGELOG.md)

**English** · [中文](README.zh-CN.md)

<p align="center"><img src="docs/showcase.png" alt="Glaze Showcase — every capability in one window" width="720"></p>

## Why Glaze?

Racket's `racket/gui` works but is hard to style into a modern product-grade UI. Glaze takes a different approach: Racket serves the local application frontend and displays it inside a **native desktop window** backed by the OS WebView — WebView2 on Windows, WKWebView on macOS, and WebKitGTK on Linux.

You get:

- **Racket for logic** — the full power of Racket's macro system, contracts, pattern matching
- **Web for UI** — Tailwind, Svelte, React, or any web framework
- **Native desktop shell** — a real OS window with an embedded system WebView
- **JSON API bridge** — the page calls Racket with plain `fetch("/api/...")`

Glaze is deliberately **GUI-first**. If the required native WebView runtime is missing or broken, startup fails with platform-specific installation/repair instructions. It does **not** silently turn the desktop app into a browser tab.

### How it compares

| | Glaze | Tauri | Electron | wails |
|---|---|---|---|---|
| Backend language | Racket | Rust | JS/Node | Go |
| Native toolchain needed | **none** (pure FFI) | Rust + cargo | none | Go + WebView2 deps |
| Binary size | tiny (Racket exe + assets) | small | 100 MB+ | small |
| Frontend→backend | HTTP JSON routes (`fetch`) | `invoke()` IPC | Node APIs | bindings |
| WebView backends | WebView2 / WKWebView / WebKitGTK | system WebView | bundled Chromium | WebView2/WKWebView |
| Missing WebView behavior | **fail fast + install guidance** | prerequisite error | n/a (bundled) | prerequisite error |
| Agent-friendly UI verification (`title`/`url`/screenshot) | **built-in** | via WebDriver | via CDP | limited |

All three WebView backends pass the real-window CI e2e (open, load, capture, navigate, close, on-close). Remaining honest gaps: no typed IPC layer (plain JSON), Linux needs a desktop session or Xvfb.

## Platform status

| Capability | macOS | Windows | Linux |
|---|---|---|---|
| Local HTTP application server | ✅ | ✅ | ✅ |
| System tray | ✅ | ✅ | ✅ (CI-verified) |
| JSON API bridge | ✅ | ✅ | ✅ |
| Native WebView window | ✅ verified end-to-end | ✅ CI e2e (WebView2) | ✅ CI e2e (Xvfb + WebKitGTK) |
| `webview-title` / `webview-url` | ✅ | ✅ | ✅ |
| `webview-capture!` (screenshot) | ✅ | ✅ (PrintWindow + PowerShell PNG) | ✅ (gdk_pixbuf) |
| `#:devtools?` | ✅ (inspectable, macOS 13+) | ✅ (`OpenDevToolsWindow`) | ✅ (WebKitGTK inspector) |

Native WebView support is mandatory for application startup. `run-app` and `open-window` never open the system browser as a fallback.

## Requirements

| Platform | Runtime requirement |
|---|---|
| All | [Racket](https://racket-lang.org/) 7.0 or later (includes `raco`) |
| Windows | Microsoft Edge WebView2 Runtime (Evergreen). Glaze ships `WebView2Loader.dll`; install/repair the Runtime if startup says it is unavailable. |
| macOS | WKWebView is built into macOS; run inside a logged-in graphical session. |
| Linux | GTK 3 + WebKitGTK (`libwebkit2gtk-4.1-0` on current Debian/Ubuntu; distro equivalent elsewhere) and a graphical desktop session/Xvfb. |

When startup cannot initialize the native backend, Glaze preserves the underlying backend error and adds actionable installation/repair guidance. Interactive desktop apps also attempt to show the same diagnosis in an OS-level error dialog, which matters for packaged Windows `--gui` executables that have no console. CI suppresses the dialog automatically; `GLAZE_NO_STARTUP_DIALOG=1` disables it explicitly.

## Quick Start

### 1. Install

```bash
raco pkg install --auto glaze
```

A single Racket package: this installs the `glaze` library, the `raco glaze` CLI, and the documentation (browse it later with `raco docs`).

### 2. Create a new project

```bash
raco glaze init myapp
cd myapp
```

### 3. Run

```bash
racket main.rkt
# or
raco glaze dev
```

A native desktop window opens and hosts the frontend served by the local Racket server. If the required WebView runtime is missing, startup stops and tells you what to install instead of opening Chrome/Edge/Safari.

> Prefer installing straight from a GitHub checkout instead of the catalog?
> ```bash
> git clone https://github.com/turinglambdaai/glaze.git
> cd glaze
> raco pkg install --auto --link "$PWD"
> ```
> To work on Glaze itself, see [CONTRIBUTING.md](CONTRIBUTING.md).

## CLI Commands

```bash
raco glaze init <name>       # Create a native Glaze desktop project
raco glaze dev               # Run this project's native desktop app
raco glaze build             # Build a distributable (exe + bundled assets)
raco glaze keygen            # Create an RSA keypair for license signing
raco glaze license           # Sign or verify offline license files
raco glaze help              # Show help
```

There is intentionally no browser-mode `dev`/`serve` command. Development and production use the same native WebView path so missing dependencies and native-backend failures cannot be hidden by a browser fallback.

### `build`

Package a Glaze project into a platform distribution (`raco exe` + `raco distribute`) with the frontend assets bundled alongside the executable. On macOS the distribution is a proper `.app` bundle with your `--version` stamped into `Info.plist`.

```bash
raco glaze build --name myapp
raco glaze build --name myapp --version 1.2.0 --installer
```

Options: `--name`, `--version`, `--icon <.ico/.icns>`, `--entry <path>` (default `main.rkt`), `--out <dir>` (default `dist`), `--embed-dlls` (Windows: single-file exe), `--installer`.

> The installer step probes for the native packaging toolchain (WiX / NSIS on Windows, `create-dmg` / `hdiutil` on macOS, `appimagetool` / `linuxdeploy` on Linux) and **degrades gracefully** to a `.zip` / `.tar.gz` when that packaging toolchain is absent, printing a warning naming what to install. This packaging fallback is unrelated to application startup: the app itself still requires a native WebView.

### Code signing & notarization

Unsigned apps get blocked by macOS Gatekeeper and Windows SmartScreen. `build` drives the platform signer for you:

```bash
# macOS — Developer ID identity, hardened runtime, notarize + staple:
raco glaze build --name myapp \
  --sign "Developer ID Application: Acme Inc (TEAMID)" \
  --notarize acme-notary --installer

# macOS — ad-hoc (no cert; for local testing / CI):
raco glaze build --name myapp --sign -

# Windows — signtool with a certificate thumbprint (RFC-3161 timestamped):
raco glaze build --name myapp --sign 40HEXCHARS --installer
```

Details: `--sign` takes a codesign identity (macOS) or a SHA-1 thumbprint / subject name for `signtool` (Windows). Hardened runtime is applied automatically on macOS unless `--no-hardened-runtime` is passed (and is skipped for ad-hoc, where its library validation would reject the app's own framework). `--notarize <keychain-profile>` submits the built dmg via `notarytool`, waits, and staples the ticket. `--entitlements <file>`, `--timestamp-url <url>` round it out. Signing failures abort the build; a *missing toolchain* degrades with a loud warning.

### Licensing (paid apps)

`glaze/license` ships an offline license-key scheme with zero native dependencies — RSA-2048/SHA-256 signatures via the system `openssl` CLI:

```bash
raco glaze keygen --out keys
raco glaze license sign --key keys/private.pem --product "MyApp" \
  --subject "customer@example.com" --expiry 2027-12-31 --out app.license
raco glaze license verify --pub keys/public.pem --product "MyApp" app.license
```

```racket
(require glaze/license)

(define r (validate-license "app.license" #:public-key "keys/public.pem" #:product "MyApp"))
(unless (hash-ref r 'valid)
  (error 'myapp "license invalid: ~a" (hash-ref r 'reason)))

(issue-license ... #:machine-id (machine-id))
```

Failure reasons are stable tags (`missing-file`, `malformed`, `signature`, `product`, `expired`, `machine`, `openssl-unavailable`) suitable for UI messages. Honest scope: this defends against casual license sharing — a local attacker can always patch a binary; it is not tamper resistance.

### Update integrity

`check-update` passes through an optional `"sha256"` manifest field; verify a downloaded artifact before swapping it in:

```racket
(define info (check-update manifest-url #:current-version "1.0.0"))
(verify-file-sha256 artifact (hash-ref info 'sha256))
```

## Project Structure

A new Glaze project looks like this:

```
myapp/
├── main.rkt          # Racket entry point
└── public/
    └── index.html    # Frontend
```

`raco glaze init` generates a native-window entry point. The call is deliberately top-level so the same file also starts correctly when `raco glaze build` packages it through the generated wrapper:

```racket
#lang racket/base

(require racket/runtime-path
         glaze)

(define-runtime-path public "public")

(run-app #:public-dir public
         #:title "myapp")
```

`run-app` starts the local HTTP application server, opens the native WebView window, and shuts the server down when the window closes. A native-backend failure is fatal and includes dependency guidance.

## Repository Structure

One installable package at the repo root; each top-level directory is a Racket collection:

```
glaze/                # repo root = the `glaze` package (info.rkt)
├── glaze/            # Library: server, API bridge, webview, tray, sys, build, app
├── glaze-cli/        # CLI tool (raco glaze init / dev / build)
├── glaze-doc/        # Documentation (Scribble)
├── glaze-test/       # Test suite
├── examples/         # Runnable examples
└── scripts/          # CI helper scripts (webview e2e)
```

## API

### `run-app`

The one-call entry: picks a free port, starts the server (static + JSON API), opens the native WebView window, and blocks until the window closes.

```racket
(run-app #:public-dir "public"
         #:api (list (GET "api/ping" ...)))
;; window closes -> server stops -> (values 'webview shutdown)
```

If native WebView startup fails, `run-app` shuts down the local server and raises the same actionable startup error. There is no `#:fallback-browser?` option.

### `start-server` / `start-dev-server`

Starts a local HTTP server serving static files with SPA fallback, plus optional JSON API routes. `start-dev-server` is a backward-compatible alias for the server primitive; it does not define Glaze's application UI mode.

```racket
(start-server #:port 8080
              #:public-dir "public"
              #:api (list (GET "api/ping" (lambda (req) (hasheq 'pong #t)))))
```

### `open-browser`

Low-level utility for opening an external URL in the user's default browser (for example, product documentation or an OAuth page). `run-app` and `open-window` do not call it as a fallback.

```racket
(open-browser "https://example.com/docs")
```

## JavaScript Bridge

The embedded frontend calls Racket with plain `fetch("/api/...")` — Glaze's answer to Tauri's `invoke()`. The local HTTP bridge is easy to exercise independently with developer tools such as `curl`.

```racket
(require glaze)

(GET  "api/ping"            (lambda (req) (hasheq 'pong #t)))
(POST "api/items/:id/bump"  (lambda (req id) (hasheq 'id id 'bumped #t)))
(POST "api/echo"            (lambda (req)
                              (define body (request-json-body req))
                              (hasheq 'echo body)))
```

- Handlers take the request plus captured `:params`; return a jsexpr (auto-wrapped as JSON 200) or a full response.
- `request-json-body` parses the JSON body — Racket jsexpr parses JSON object keys as **symbols** (`(hash-ref body 'delta)`).
- A handler that raises becomes a 500 JSON error, never a broken connection.
- Unmatched requests fall through to static files (SPA `index.html` fallback).

### Typed routes, one declaration — `define-api-routes`

```racket
(define-api-routes api
  [(POST "api/counter/bump")
   (bump [delta exact-nonnegative-integer? 1])
   (hasheq 'count (add1 delta))])
```

One clause defines a Racket procedure, a validated HTTP route, and a JS client entry exposed by `/glaze/api.js`.

### Backend → frontend push (SSE)

```racket
(define bus (make-event-bus))
(start-server ... #:events bus)
(bus-broadcast! bus 'count-changed (hasheq 'count 42))
```

```js
glaze.on('count-changed', s => render(s.count));
```

The event stream uses the same local origin as the embedded WebView frontend.

### Security

- Requests are only served for Host headers `127.0.0.1` / `localhost` / `[::1]`.
- API handler parameter errors become 400 JSON; handler exceptions become 500 JSON and reach `run-app`'s `#:on-error` hook.
- Optional `#:api-token` protects API routes and SSE. The native app window uses a one-time bootstrap URL to obtain an HttpOnly cookie; programmatic clients use `X-Glaze-Token`.
- Update checks remain opt-in through `run-app #:check-update ...`.

## System Integrations (`glaze/sys`)

```racket
(require glaze/sys)
(clipboard-set! "hello")
(notify! "Download finished" "report.pdf is ready")
(open-path "/Users/me/report.pdf")
(reveal-path "/Users/me/report.pdf")
(unless (single-instance? "com.me.app") (exit 0))
```

Window controls include `webview-set-title!`, `webview-set-size!`, `webview-set-fullscreen!`, and `webview-focus!`.

## System Tray

Glaze provides a cross-platform system tray:

- **Windows** — `Shell_NotifyIconW`
- **macOS** — `NSStatusItem` / `NSMenu`
- **Linux** — `libayatana-appindicator` + `libgtk-3`

The tray is an optional integration. If its backend is unavailable it may degrade to an inert stub; that is intentionally different from the mandatory main WebView.

## App Platform APIs

```racket
(require glaze)

(define f (pick-file #:title "Open report" #:filters '(("Reports" "*.rep" "*.csv"))))
(define dir (pick-folder #:title "Where?"))
(define out (save-file-dialog #:title "Save as" #:default-name "out.rep"))

(webview-set-menu! wv
  (list (make-menu "File"
                   (list (make-menu-item "Open…" #:accel "CmdOrCtrl+O"
                                         #:action open-doc)
                         menu-separator
                         (make-menu-item "Quit" #:action (lambda () (exit 0)))))))

(ensure-url-scheme! "myapp")
(auto-launch-set! "MyApp" #t)
(auto-launch-enabled? "MyApp")

(for ([w (all-webviews)]) (webview-focus! w))
(wait-for-webviews)
```

## Examples

| Example | What it shows |
|---|---|
| [`examples/showcase/`](examples/showcase/) | **Kitchen sink (start here)** — every capability in one native window |
| [`examples/hello/`](examples/hello/) | Minimal native app — `run-app` in 8 lines |
| [`examples/counter/`](examples/counter/) | JS↔Racket bridge — `fetch` calls Racket state |
| [`examples/webview-demo.rkt`](examples/webview-demo.rkt) | Cross-platform native WebView lifecycle: load, navigate, close, verification APIs |
| [`examples/agent-verify.rkt`](examples/agent-verify.rkt) | Agent workflow: assert page state + screenshot with no human |
| [`examples/tray-demo.rkt`](examples/tray-demo.rkt) | Cross-platform system tray with a working menu |

## Roadmap

- [x] **Phase 1** — Local HTTP server + early browser prototype
- [x] **Phase 2** — Frontend asset bundling, system tray, app packaging
- [x] **Phase 3** — Native WebView embedding (WebView2 / WKWebView / WebKitGTK) — verified by the 3-OS CI e2e
- [x] **GUI-first contract** — native WebView required; actionable failure instead of browser fallback

## License

Licensed under the [MIT License](LICENSE).
