# Glaze

A Lisp-native framework for building modern desktop applications with Racket.

Glaze lets you keep application logic in Racket, build the UI with normal web technologies, and connect that UI to native desktop capabilities such as WebView windows, system tray menus, clipboard access, notifications, dialogs, and application packaging.

[![CI](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

## Why Glaze

Racket already has `racket/gui`, but Glaze targets a different style of desktop application: web UI on top of a Racket runtime.

Glaze is not an Electron clone. It does not bundle Chromium or introduce a Node runtime. Its current model is closer to Tauri in spirit:

```text
Web UI
  |
  | HTTP / JSON / SSE
  v
Racket runtime
  |
  +-- WebView
  +-- Tray
  +-- System capabilities
  +-- Packaging helpers
  |
Native OS APIs
```

The framework currently uses the operating system WebView through Racket FFI:

- Windows: WebView2
- macOS: WKWebView
- Linux: WebKitGTK

Glaze is deliberately GUI-first. A working native WebView is required: when
the backend is missing or broken, startup fails with platform-specific
installation or repair guidance instead of silently opening a browser tab.

The frontend/backend bridge today is intentionally simple: local HTTP JSON routes for requests and Server-Sent Events for backend-to-frontend events. A larger RPC or plugin system is not part of the current public architecture.

## Quick Start

Install the package:

```bash
raco pkg install --auto glaze
```

Or link a checkout for development:

```bash
git clone https://github.com/turinglambdaai/glaze.git
cd glaze
raco pkg install --auto --no-docs --link "$PWD"
```

A minimal application can use the single public facade:

```racket
#lang racket/base

(require racket/runtime-path
         glaze)

(define-runtime-path public "public")

(run-app #:public-dir public
         #:title "Hello Glaze")
```

Put an `index.html` file in `public/`, then run the Racket program. See [`examples/hello/`](examples/hello/) for the complete minimal example.

The CLI can also scaffold a project:

```bash
raco glaze init myapp
cd myapp
racket main.rkt
```

## Features

Implemented today:

- native WebView windows with lifecycle, navigation, title/URL inspection, screenshots, window controls, and menu integration
- local static-file server with SPA fallback
- JSON API routes and generated browser client support
- Server-Sent Events for backend-to-frontend events
- system tray menus
- clipboard, notifications, open/reveal helpers, and single-instance support
- file dialogs, deep-link helpers, and autolaunch helpers
- application packaging through `raco glaze build`
- update and offline-license utilities
- actionable diagnostics when a required native WebView is unavailable

Glaze is implemented in Racket and uses FFI for native integrations; the core framework does not require a C compiler.

## Platform Support

The repository CI tests Racket 8.12 on Windows, macOS, and Linux. Native WebView end-to-end tests run on all three platforms; Linux uses Xvfb plus WebKitGTK in CI.

| Capability | Windows | macOS | Linux |
|---|---|---|---|
| Local server / JSON API / SSE | Yes | Yes | Yes |
| Native WebView | WebView2 | WKWebView | WebKitGTK |
| System tray | Yes | Yes | Yes |
| System helpers | Yes | Yes | Yes |
| Packaging pipeline | Yes | Yes | Yes |

Some native features depend on platform libraries or desktop-session availability. WebView startup failures are fatal and include platform-specific guidance; application code should not import a platform implementation directly. See [`docs/gui-first.md`](docs/gui-first.md) for runtime requirements and diagnostics.

## Architecture

The current repository already has a useful boundary: applications can depend on `(require glaze)`, while WebView, tray, and system modules dispatch to platform backends internally.

```text
Application
    |
    v
(require glaze)
Public facade: glaze/main.rkt
    |
    +-------------------------------+
    |               |               |
    v               v               v
Runtime          Capabilities     Tooling
app/server       webview/main     build/update
api/events       tray/main        CLI
                 sys/main
    |               |
    +-------+-------+
            v
Platform backends
Windows / macOS / Linux / stub
```

This PR-sized architecture is deliberately smaller than the long-term vision. The next goal is to make dependency direction and lifecycle contracts clearer without moving every implementation file.

See [`docs/architecture.md`](docs/architecture.md) for the detailed boundary and dependency rules.

## Packages and Collections

The repository root is one installable Racket package using `collection 'multi`. The main top-level collections are:

- `glaze/` — framework library and public facade
- `glaze-cli/` — `raco glaze` commands
- `glaze-doc/` — Scribble documentation
- `glaze-test/` — test suite
- `examples/` — runnable examples (excluded from package setup compilation)
- `scripts/` — CI and verification scripts

Inside `glaze/`, `webview/`, `tray/`, and `sys/` each contain a public dispatcher plus platform-specific backends. Applications should normally use `(require glaze)` instead of importing backend modules.

## Examples

Start with the small examples before the full showcase:

- [`examples/hello/`](examples/hello/) — minimal `run-app` application
- [`examples/tray/`](examples/tray/) — system tray and menu actions
- [`examples/events/`](examples/events/) — JSON request + SSE event push
- [`examples/counter/`](examples/counter/) — fuller JS/Racket bridge example
- [`examples/showcase/`](examples/showcase/) — integrated feature showcase
- [`examples/agent-verify.rkt`](examples/agent-verify.rkt) — programmatic WebView verification
- [`examples/webview-demo.rkt`](examples/webview-demo.rkt) — direct WebView lifecycle demo

## Project Status

Glaze is a pre-1.0 project (`0.7` in package metadata). It already contains working cross-platform implementations and CI coverage, but API boundaries are still being stabilized.

For new applications, prefer the `glaze` facade and documented APIs. Direct imports of files such as `webview-windows.rkt`, `tray-macos.rkt`, or `sys-linux.rkt` are implementation details and should not be treated as stable application APIs.

Backward compatibility is preferred during the 0.x stabilization work; large rewrites and unnecessary file moves are intentionally avoided.

## Roadmap

See [`ROADMAP.md`](ROADMAP.md). The near-term focus is lifecycle, public API clarity, examples, tests, and documentation. IPC/event refinements and additional capabilities come later; a plugin SDK and hot reload are explicitly not part of the current stabilization pass.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — architecture and dependency rules
- [`ROADMAP.md`](ROADMAP.md) — small staged roadmap
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — contributor workflow
- `raco docs glaze` / the `glaze-doc` collection — API reference

## Development

```bash
raco pkg install --auto --no-docs --link "$PWD"
raco make glaze/main.rkt glaze-cli/cli.rkt
raco test glaze-test/
```

CI additionally runs native WebView end-to-end tests and a packaging smoke build on Windows, macOS, and Linux.

## Contributing

Contributions are welcome. Please keep changes small enough to review, preserve existing APIs where practical, add regression tests for behavior changes, and keep platform-specific code behind the dispatcher modules.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the repository workflow.

## License

MIT — see [`LICENSE`](LICENSE).
