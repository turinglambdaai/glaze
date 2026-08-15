# Changelog

All notable changes to Glaze will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.3.0] - Unreleased

### Fixed (Phase 3, in progress)
- **Windows WebView2 root cause found and fixed**: the long-standing
  "COM apartment" diagnosis was wrong — `get_CoreWebView2` was being called
  at vtable slot 3 (actually `get_IsVisible`, which writes a BOOL into the
  out-pointer), yielding a garbage pointer that crashed on any vtable
  access. All vtable indices are now verified against the official
  Microsoft.Web.WebView2 SDK header. The backend additionally: AddRefs and
  retains the controller/CoreWebView2 for post-open navigate, implements
  title/url (get_DocumentTitle / get_Source) and capture! (PrintWindow +
  PowerShell BMP->PNG), sizes the WebView to the client area, and wires
  WM_CLOSE to on-close. Runtime verification pending the new CI e2e job.
- Linux backend: capture! via gdk_pixbuf; CI e2e job added (Xvfb +
  WebKitGTK) alongside macOS/Windows real-window e2e.
- `open-window`/`open-webview` accept `#:devtools?` (macOS:
  setInspectable:; Windows: OpenDevToolsWindow; Linux: not yet).

### Added (Phase 3, in progress)
- **JavaScript bridge** (`glaze/api`): real JSON routing over the frontend
  server — `GET`/`POST`/`PUT`/`DELETE` route values with `:param` capture,
  `request-json-body` (jsexpr, symbol keys), jsexpr auto-wrapping, 500-JSON
  on handler errors; unmatched paths fall through to static SPA serving.
  Replaces the old no-op `define-api` macro. One code path works in the
  webview, the browser fallback, and curl.
- **`run-app`** (`glaze/app`): one-call composition — free-port picking,
  server + API + webview window lifecycle, `#:on-ready` hook (agent
  verification point), graceful system-browser fallback with explicit
  shutdown semantics.
- **`start-server` now verifies the listener is accepting** before
  returning; bind/listen failures surface as a clear error instead of a
  later "connection refused" (fixes a long-standing flaky e2e symptom).
- **Linux webview backend structurally fixed**: the blocking `gtk_main` call
  (which would freeze the whole Racket scheduler) is replaced by a
  g_main_context_iteration pump with scheduler yields, mirroring the
  verified macOS design; `destroy`-signal on-close registry; `title`/`url`
  wired to WebKitGTK getters. Runtime-verification on a Linux host pending.
- **Examples**: hello (minimal run-app), counter (JS↔Racket bridge),
  agent-verify (no-human UI verification), tray-demo, webview-demo.
- Support matrix + framework comparison in README (en/zh).
- **Native WebView embedding** (`glaze/webview`): public `open-window` /
  `open-webview` API with platform backend dispatch (windows/macos/linux/stub),
  mirroring the tray design and falling back to the stub when native deps are
  missing. `#:fallback-browser?` opens the system browser when the native
  backend is unavailable.
- **Verification APIs** (agent-friendly): `webview-title`, `webview-url`, and
  `webview-capture!` (window screenshot to PNG) let automated callers assert
  on UI state without a human at the screen. Fully implemented on macOS;
  other backends degrade to `#f`.
- **Windows backend** (pure Racket FFI): the WebView2 async init chain through
  controller delivery is verified working via hand-built COM CompletedHandler
  vtables; ships `WebView2Loader.dll`. Completing `Navigate` is pending a COM
  apartment/lifetime fix.
- **macOS backend** (`ffi/unsafe/objc`, verified end-to-end): NSWindow + WKWebView
  with a manual run-loop pump (`runMode:beforeDate:`) that services AppKit events
  and WebKit's IPC sources without blocking Racket's scheduler; window delegate
  delivers `#:on-close`; autoresizing WKWebView; programmatic close and
  `webview-navigate` both supported.
- **Linux backend** (`ffi/unsafe`): GtkWindow + WebKitGTK 4.1 skeleton.

## [0.2.0] - Unreleased

### Added
- **Frontend asset bundling**: `start-server` (canonical entry, `start-dev-server`
  kept as alias); expanded MIME table (webp, avif, wasm, mp4, mjs, …);
  `define-runtime-path`-based embedded public dir so packaged apps resolve
  assets without depending on the working directory.
- **System tray** (`glaze/tray`): cross-platform API
  (`make-tray`, `tray-set-tooltip!`, `tray-set-icon!`, `tray-set-menu!`,
  `tray-close`) with pure-Racket-FFI backends — Windows
  (`Shell_NotifyIconW`), macOS (`NSStatusItem` via `ffi/unsafe/objc`), Linux
  (`libayatana-appindicator` + `libgtk-3`). Gracefully degrades to a no-op stub
  when native libraries are missing.
- **App packaging** (`raco glaze build`): wraps `raco exe` + `raco distribute`,
  bundles `public/` next to the executable, post-processes the macOS `.app`
  `Info.plist`. `--installer` flag produces platform installers
  (msi / dmg / AppImage) and falls back to zip / tar.gz when the toolchain is
  absent.
- CI `package` job builds a sample app on all three OSes and uploads the
  distribution + installer as artifacts.

## [0.1.0] - Unreleased

### Added
- Local HTTP server for serving web frontend
- Static file serving from `public/` directory
- `raco glaze init <name>` to scaffold new projects
- `raco glaze dev` to start dev server with auto-open browser
- Cross-platform browser opener (Windows/macOS/Linux)
- MIT License
