# Changelog

All notable changes to Glaze will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.3.0] - Unreleased

### Added (Phase 3, in progress)
- **Native WebView embedding** (`glaze/webview`): public `open-window` /
  `open-webview` API with platform backend dispatch (windows/macos/linux/stub),
  mirroring the tray design and falling back to the stub when native deps are
  missing.
- **Windows backend** (pure Racket FFI): the WebView2 async init chain through
  controller delivery is verified working via hand-built COM CompletedHandler
  vtables; ships `WebView2Loader.dll`. Completing `Navigate` is pending a COM
  apartment/lifetime fix.
- **macOS backend** (`ffi/unsafe/objc`): NSWindow + WKWebView skeleton.
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
