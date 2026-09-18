# Glaze Examples

Start with the smallest examples. They use the public `(require glaze)` facade and show the recommended application-facing APIs without exposing platform backend modules.

| Example | Purpose | Main capabilities |
|---|---|---|
| [`hello/`](hello/) | Minimal desktop application | `run-app`, static assets, native WebView/browser fallback |
| [`tray/`](tray/) | Minimal system tray application | `make-tray`, menu items, tray lifecycle |
| [`events/`](events/) | Minimal JS/Racket communication | JSON request route + Server-Sent Events push |
| [`counter/`](counter/) | Fuller bridge example | `define-api-routes`, generated client support, event bus, shared state |
| [`showcase/`](showcase/) | Integrated feature showcase | API validation, events, system capabilities, WebView controls, tray, update checks |
| [`webview-demo.rkt`](webview-demo.rkt) | Direct WebView lifecycle | open, navigate, inspect, capture, close |
| [`agent-verify.rkt`](agent-verify.rkt) | Programmatic UI verification | polling assertions, title/URL inspection, screenshot, exit status |
| [`tray-demo.rkt`](tray-demo.rkt) | Legacy single-file tray demo | tray menu and tooltip updates |

## Quick Start

```bash
racket examples/hello/main.rkt
racket examples/events/main.rkt
racket examples/tray/main.rkt
```

Then move to the fuller examples:

```bash
racket examples/counter/main.rkt
racket examples/showcase/main.rkt
```

The examples intentionally use public modules. Backend-specific modules under `glaze/webview/`, `glaze/tray/`, and `glaze/sys/` are implementation details unless you are working on Glaze itself.
