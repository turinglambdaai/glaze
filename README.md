# Glaze

Build desktop apps with Racket backend and web frontend.

A [Tauri](https://tauri.app/)-like framework for [Racket](https://racket-lang.org/). Write your app logic in Racket, build your UI with web technologies (HTML/CSS/JS), and ship a desktop application.

## Why?

Racket's `racket/gui` is functional but hard to style into a modern product-grade UI. Glaze takes a different approach: serve a local web app from Racket and display it in the system browser (Phase 1) or an embedded WebView (Phase 3).

You get:
- **Racket for logic** — all the power of Racket's macro system, contracts, pattern matching
- **Web for UI** — Tailwind, Svelte, React, whatever you want
- **JSON API bridge** — Racket macros auto-generate API endpoints

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

## Project Structure

```
myapp/
├── main.rkt          # Racket entry point
└── public/
    └── index.html    # Frontend
```

## Roadmap

- [x] **Phase 1** — Local HTTP server + system browser
- [ ] **Phase 2** — Frontend asset bundling, system tray, app packaging
- [ ] **Phase 3** — Native WebView embedding (WebView2 / WKWebView / WebKitGTK)

## License

MIT
