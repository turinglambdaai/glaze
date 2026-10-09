# Changelog

All notable changes to Glaze will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Package Linux apps as deb and rpm alongside AppImage, matching the Tauri
  bundler's format matrix. Every available format is built from one FHS
  staging tree (`/usr/lib/<app>` payload, `/usr/bin/<app>` wrapper,
  `.desktop` entry, hicolor icon); AppImage now gets a real populated
  AppDir instead of relying on one existing, and projects without an icon
  ship a valid generated placeholder PNG (pure Racket zlib/PNG encoder).
  CI builds and validates all three formats per run.

## [0.10.0] - 2026-10-09

### Added
- Add Tauri-style global shortcuts: system-wide hotkeys with
  `CmdOrCtrl+Shift+D` accelerators, capability-gated register, unregister,
  unregister-all, and is-registered routes with accelerator scopes
  (exact strings or explicit regexps, canonicalized on both sides), and
  `global-shortcut` SSE events on trigger. Native backends use Win32
  `RegisterHotKey` through a message-only window, Carbon
  `RegisterEventHotKey`, and X11 `XGrabKey`.
- Add structured logging: one logger with per-sink minimum levels, a
  rotating file sink (rotation instead of truncation), SSE `log` events,
  bounded in-memory history, and capability-gated frontend write/history
  routes. Frontend records are tagged with their source and capability so
  pages cannot forge backend log lines.
- Add capability-gated native dialog routes over the existing pickers:
  open (single/multiple/folder), save, message, and ask, with native
  message boxes on every platform and JSON filter specs. Open and save
  scopes pin the starting directory; the backend is injectable so tests
  and headless CI never open real dialogs.

### Fixed
- Stage `WebView2Loader.dll` into the packaged Windows distribution (and
  therefore every MSI harvested from it): the loader is FFI-loaded through
  an absolute package-tree path that `raco distribute` cannot trace, so
  packaged apps previously exited with `WebView2 backend unavailable` at
  startup. CI now asserts the staged copy on the Windows package job.

## [0.9.0] - 2026-10-09

### Fixed
- Follow absolute and relative HTTP redirects in legacy update checks, signed
  manifest fetches, and artifact downloads, with a ten-hop limit and no HTTPS
  downgrade for signed updates. This also removes a contract-violating OpenSSL
  probe that made HTTPS legacy checks silently fail on Racket 9.3.
- Drive the macOS AppKit event cycle with `nextEvent`, `sendEvent`, and
  `updateWindows` while continuing to service main-runloop sources. This fixes
  WKWebView pages that load and execute but remain visually white on macOS 26.
- Strengthen real-window CI with a high-entropy canvas capture so a committed
  page title cannot hide a missing first paint.

### Changed
- Harden Windows installers with configurable publisher and stable application
  identifiers, deterministic WiX upgrade codes, and complete NSIS silent
  install/uninstall metadata for Windows Apps & Features and winget.
- Publish a validated, self-contained Windows MSI and SHA-256 checksum beside
  the source archive for every tagged Glaze release.

### Added
- Add a complete signed update pipeline alongside the legacy notification
  helper: SemVer/channel selection, application and key-id pinning, staged
  rollout, bounded HTTPS downloads, SHA-256 and optional Ed25519 artifact
  verification, atomic portable replacement, install/restart callbacks, and
  failure rollback.
- Add `raco glaze manifest-sign` and `manifest-verify` so release automation
  can validate, sign, and verify the exact manifest consumed by applications.
- Add cross-platform window geometry and Tauri-style opt-in window-state
  persistence. Windows, macOS, and Linux now expose outer position, size, and
  maximized state; `run-app #:app-id ... #:window-state #t` restores it and
  clamps stale coordinates to the current virtual desktop.
- Add a Tauri-style runtime authority layer. Opt-in capabilities make API
  routes default-deny, bind authority to the WebView token, omit ungranted
  routes from the generated client, and support deny-first path and
  command/argument scopes.
- Add a capability-gated filesystem plugin with direct Racket procedures and
  generated frontend routes for text/base64 I/O, directories, metadata,
  existence checks, copy, move, and removal. Multi-path operations authorize
  both source and destination; writes use atomic same-directory replacement.
- Add a capability-gated shell/process plugin with direct execution, bounded
  stdout/stderr capture, environment and working-directory options, timeouts,
  and capability-owned background handles for stdin, status, and termination.
  Frontend environment names and working-directory roots are opt-in, and the
  retained process registry is bounded.
- Add a capability-gated persistent JSON store plugin with defaults,
  debounced auto-save, atomic writes, reload/reset/save/close lifecycle,
  deterministic enumeration, rooted paths, and optional SSE change events.
- Add capability-gated frontend routes for clipboard text, notifications,
  opening and revealing scoped paths, opening scoped URLs, and OS information.
  Clipboard read/write and hostname access are independently granted; URL
  scopes accept exact strings or explicit regular expressions.
- Add a Tauri-style path resolver for application, user, temporary,
  executable, and resource directories; portable/per-directory overrides;
  resource-root confinement; and capability-gated frontend path utilities.
- Add a capability-gated HTTP/HTTPS client with text/base64 bodies, bounded
  request and response sizes, total timeouts, controlled redirects, and
  generated frontend access. Every redirect is re-authorized; cross-origin
  redirects strip credentials and connection-managed headers are rejected.
- Add a capability-gated SQLite plugin with parameterized select/execute,
  load/close lifecycle, affected-row and insert-id results, JSON NULL and
  base64 BLOB conversion, confined database paths, bounded results and
  capability-owned connection caching.

## [0.8.0] - 2026-09-30

### Changed
- Require Racket 9.0+ with the CS runtime (`base #:version "9.0"`). The BC
  engine and pre-9.0 releases are no longer supported or tested.

### Added
- Make new projects agent-native with a generated `AGENTS.md`, a native UI
  `verify.rkt`, `raco glaze inspect --json`, and `raco glaze verify`.
- Extend `raco glaze doctor` with machine-readable JSON and native WebView
  readiness diagnostics while retaining its human-readable package repair flow.

### Fixed
- Make `examples/agent-verify.rkt` return nonzero when native verification is
  unavailable or any assertion fails, so automation cannot report a false pass.

## [0.7.0] - 2026-09-29

### Added
- Add `glaze/signing` and `raco glaze updater-keygen`, `update-sign`, and
  `update-verify` for Ed25519-signed update artifacts. Private keys may be
  password-encrypted, the installed application can pin the public key, and
  signatures cover the artifact's SHA-256 digest without loading it in memory.

### Fixed
- Build the Scribble reference manual in CI and group modules that share a
  manual section, eliminating duplicate exporting-library warnings during
  package-catalog documentation builds.
- **`raco glaze license sign --machine-id <id>` produced licenses that
  could never verify**: sign stored the given raw machine identifier
  verbatim while validate compares against the `(machine-id)` digest, so
  every CLI-signed machine-bound license failed with reason "machine".
  Sign now normalizes the value (raw id hashed; a 64-hex digest passes
  through); `sha256-hex` is exported from `glaze/license` for this.
- **`#:check-update` stalled app startup**: run-app performed the update
  check synchronously before opening the window, so a slow or blocked
  network held first paint for the manifest timeout (seconds). The check
  now runs in a background thread; the `'update-available` broadcast
  contract is unchanged.
- **Linux tray aborted standalone processes**: `tray-linux` never called
  `gtk_init` — inside a webview app the window backend had already done it,
  but tray-only processes (and `raco test glaze-test/` on a Linux desktop)
  aborted inside appindicator with "Can't create a GtkStyleContext without
  a display connection". `make-tray` now initializes GTK once per process.
- **Linux WebView backend broke the packaged app at the first
  `open-window`**: `webview-linux` implements the full backend contract but
  its `provide` list was missing `focus!`, `set-menu!`, and `closed?` — the
  dispatcher `dynamic-require`s all 13 names, so every Linux app died with
  "name is not provided" the moment a window opened (headless CI never
  exercises the dispatch path). The backend-contract test now asserts the
  current platform's backend provides all 13 dispatcher names.
- **Packaged apps shipped without the platform backend modules**: the
  webview/sys/tray schedulers pick their backend via `dynamic-require` at
  runtime, which `raco exe`'s static walk cannot see. `build-app`
  (`raco glaze build`) now embeds the current platform's backends
  explicitly (`++lib`), and exports `platform-backend-modules` for scripts
  that call `raco exe` directly. Symptom before: the app started and every
  headless check passed, then the first native window (or alarm
  notification) died with "collection not found:
  glaze/webview/webview-linux" — found while packaging gPTP Studio v1.0.0.
- **`glaze/ffi-discovery`** (new): shared foreign-library discovery,
  replacing the three copy-pasted `try-ffi-lib` implementations in the
  webview/sys/tray Linux backends. It takes multi-soname candidates — the
  single-suffix trap (libpcap.so.1 on Fedora/Arch vs libpcap.so.0.8 on
  Debian/Ubuntu) is exactly what crashed gPTP Studio v1.0.0 at startup on
  Ubuntu — never raises, and reports failures through `ffi-lib-reason` so a
  missing native dependency is a reportable capability instead of a startup
  crash.

## [0.6.0] - 2026-09-15

### Added
- **Code signing & notarization** in `raco glaze build` / `build-app`:
  `--sign` drives `codesign` (macOS identity, `-` = ad-hoc) or `signtool`
  (Windows SHA-1 thumbprint or subject, RFC-3161 timestamped by default);
  `--entitlements`, `--no-hardened-runtime`, `--timestamp-url`,
  `--notarize <profile>` (notarytool submit + stapler) complete the
  pipeline. Signing failures abort the build; a missing toolchain degrades
  with a loud warning. macOS now assembles a canonical `.app` bundle
  (Contents/MacOS + lib + Info.plist + PkgInfo) from `raco distribute`'s
  flat output, so signing, dmg, and version metadata always have a bundle
  to work with; nested code is signed before the bundle itself (one
  `--deep` pass produces Team-ID-mismatched signatures on Apple Silicon),
  and the hardened-runtime option is skipped under an ad-hoc identity
  (its library validation would reject the app's own framework).
- **Licensing (`glaze/license`)**: offline RSA-2048/SHA-256 license files —
  `issue-license` / `validate-license` / `license-valid?` with stable
  failure reasons (`signature`, `expired`, `machine`, `product`, ...),
  `(machine-id)` machine binding (digest of IOPlatformUUID /
  /etc/machine-id / MachineGuid), and expiry math (`days-until-expiry`).
  Signatures are computed by the system `openssl` CLI — no crypto package.
  CLI: `raco glaze keygen`, `raco glaze license sign|verify`.
- **Update integrity**: update manifests may carry a `"sha256"` field
  (passed through by `check-update`); new `verify-file-sha256` checks a
  downloaded artifact before the app swaps it in.
- `build-app`/`build` gained `#:version` — stamped into the macOS
  Info.plist (`CFBundleShortVersionString` / `CFBundleVersion`) and the
  WiX MSI `ProductVersion`.
- `raco distribute` hardening: the read-only launcher `raco exe` emits no
  longer breaks `distribute`'s segment patching (EACCES on Racket 9.3).

### Changed
- macOS packaged apps resolve their `public/` directory from
  `Contents/Resources/public` (the generated entry checks the exe dir,
  then `../Resources`).

## [0.5.0] - 2026-09-15

### Changed
- **Single-package layout**: the repository root is now one installable
  `glaze` package (`info.rkt` with `collection 'multi`); the former
  `glaze` metapackage, `glaze-lib`, `glaze-cli`, `glaze-doc`, and
  `glaze-test` packages are now collections inside it. One install, one
  version, one catalog entry:
  - `raco pkg install glaze` (catalog) or `raco pkg install --link .`
    (checkout) installs everything — library, `raco glaze` CLI, docs,
    tests.
  - All public module paths are unchanged (`glaze`, `glaze/server`,
    `glaze/webview/main`, ...); nothing to migrate for app code.
  - `glaze-lib/` was renamed to `glaze/` and the test suite flattened
    from `glaze-test/glaze/test/` to `glaze-test/`.
  - `examples/` and `scripts/` carry collection-level `info.rkt` files
    so `raco setup` never compiles them.

## [0.4.0] - 2026-08-30

### Added
- **Windows desktop notifications**: `notify!` now works on all three
  platforms — Windows drives a WinRT toast through Windows PowerShell 5.1
  (present on every Windows 10/11 install), attributing to PowerShell's
  registered AppUserModelID; same blessed-subprocess pattern as macOS
  (osascript) and Linux (notify-send). XML-escaped titles/bodies; the
  script file sidesteps command-line quoting.
- **Token bootstrap hardening**: `run-app` opens the window at a one-time
  capability URL (`/?glaze-token=...`); the server exchanges the token for
  an `HttpOnly` cookie (was: `SameSite=Strict` only) and redirects to the
  clean path. **Breaking-ish:** `GET /glaze/api.js` no longer sets the
  cookie — it previously handed the token to any local caller able to read
  an openly-served endpoint, which defeated the API token entirely.
  Pages are unaffected (the redirect happens before app code runs);
  programmatic clients keep using `X-Glaze-Token`.

### Changed
- **Single shared pump thread** for all macOS webview windows (previously
  one pump thread per window, all contending for the same main run loop).
  The pump starts with the first window, exits with the last; the
  0 -> 1 open-count transition makes restart race-free.
- Windows opened with `orderFrontRegardless`, a no-op normally — a
  mitigation for the background-session white screen (see below).

### Fixed
- Multi-window macOS apps no longer spawn one OS-thread per window; the
  new multi-window e2e loads two distinct pages, closes one, verifies the
  survivor still services fresh navigations, and asserts the shared pump
  exits.

### Known issues (updated)
- Background-session white screen: windows are now also ordered front
  unconditionally; a `nohup`-detached probe on macOS 26 composites and
  captures correctly. If a white window is ever seen again, compare
  `webview-title`/`webview-url` (they work) against `webview-capture!`
  (`#f` = not composited) and prefer relaunching from a foreground
  terminal over debugging glaze.

## [0.3.0] - 2026-08-16

### Added (packaging & distribution)
- **`glaze` meta package**: `raco pkg install --auto glaze` now installs the
  library, CLI, and documentation in one command from the Racket package
  catalog. The repo follows the standard multi-package layout (meta package
  in `glaze/`, no root package), mirroring `typed-racket` / `srfi`.
- Version metadata (`0.3.0`) on the packages; CI badge and release badge in
  the READMEs; Scribble documentation extended to cover `glaze/sys`, the SSE
  event bus, `define-api-routes` + the generated JS client, update checks,
  and the security model; README platform table updated (Linux `#:devtools?`
  and Windows resize-follow are done).

### Added (system integrations)
- **`glaze/sys`**: clipboard (get/set, NSPasteboard / Win32 / GTK FFI),
  desktop notifications (osascript / notify-send; Windows pending tray or
  WinRT wiring), open/reveal paths with OS handlers, and a portable
  single-instance lock (derived-port bind, no lockfiles).
- **Window controls**: `webview-set-title!` / `webview-set-size!` /
  `webview-set-fullscreen!` across all backends.
- **macOS AppKit now loads explicitly** in the tray and sys backends:
  previously NSStatusBar & friends resolved to NULL in processes that
  hadn't loaded WebKit (which incidentally pulls AppKit in), so a
  tray-only app silently no-opped.

### Added (hardening)
- **API token** (opt-in): `start-server`/`run-app` accept `#:api-token`
  (string, or `#t` in run-app to auto-generate via make-api-token). Guards
  capabilities (API routes + the SSE stream) — not resources: static files
  and the api.js bootstrap stay open, and api.js sets the `glaze_token`
  cookie that carries the token into the page (EventSource cannot set
  headers, but same-origin requests carry cookies). Programmatic clients
  pass `X-Glaze-Token`. Missing/invalid -> 401. Honest scope: raises the
  bar against casual local callers; a determined local process can still
  fetch the token — full local isolation is not achievable over plain HTTP.
- **Error reporting**: `current-glaze-error-reporter` parameter feeds API
  handler failures (the 500 path) to `run-app`'s `#:on-error`.
- **Update checking** (`glaze/update`): `check-update` fetches a JSON
  manifest ({"version","url","notes"}), semver-aware numeric comparison
  ("1.10" > "1.9"); `run-app`'s `#:check-update` + `#:current-version`
  print and broadcast `update-available` on the event bus. Deliberately
  stops at notification — replacing a running app is a per-distribution
  decision.
- `run-app` now forwards `#:events` (routes + push in one call) and
  exposes `current-api-token` / `make-api-token`.
- Linux `#:devtools?` (WebKitGTK inspector, retry-until-realized); Windows
  webview follows window resizes (WM_SIZE -> put_Bounds).

### Added (commercial polish)
- **Event push** (`glaze/events` + SSE): make-event-bus / bus-broadcast! feed a
  built-in `GET /glaze/events` Server-Sent-Events endpoint (keepalive every
  15s, per-subscriber bounded backlog with drop-on-overflow, disconnect
  cleanup). The browser fallback gets push for free — same origin.
- **define-api-routes** (`glaze/api-macros`): one declaration yields a
  callable Racket procedure, a route with typed/optional/:path parameters
  (bad input -> 400 naming the parameter; handler errors stay 500), and a
  generated JS client entry.
- **Generated JS client**: `GET /glaze/api.js` derives `glaze.api.*`
  functions (path params become arguments), `glaze.call`, and `glaze.on`
  (EventSource wrapper) from the registered routes. Disable with
  `#:serve-api-client? #f`.
- **DNS-rebinding guard**: Host-header validation on every request
  (127.0.0.1/localhost/[::1]); hostile origins get 403.
- **macOS standard menus**: Edit (Cmd+Z/X/C/V/A) and Window (Cmd+W/M) —
  without an Edit menu, keyboard shortcuts silently do nothing in webview
  text fields.
- `start-server` rejects non-event-bus `#:events` arguments;
  `request-json-body` returns the empty hash for absent/empty bodies.

### Fixed (Phase 3)
- **Windows WebView2 root cause found and fixed**: the long-standing
  "COM apartment" diagnosis was wrong — `get_CoreWebView2` was being called
  at vtable slot 3 (actually `get_IsVisible`, which writes a BOOL into the
  out-pointer), yielding a garbage pointer that crashed on any vtable
  access. All vtable indices are now verified against the official
  Microsoft.Web.WebView2 SDK header. The backend additionally: AddRefs and
  retains the controller/CoreWebView2 for post-open navigate, implements
  title/url (get_DocumentTitle / get_Source; UTF-16 walked directly —
  bytes-open-converter is one-directional) and capture! (PrintWindow ->
  DIB -> BMP (little-endian headers) -> PowerShell PNG), sizes the WebView
  to the client area, and wires WM_CLOSE to on-close.
- Linux backend: capture! via gdk_pixbuf (get_from_window lives in
  libgtk-3, needs real window dimensions); ffi-lib gains multiarch
  absolute-path fallbacks (Racket's dlopen misses /lib/x86_64-linux-gnu
  for some libraries).
- **All three webview backends pass the real-window CI e2e** (macOS,
  Windows, Linux/Xvfb): open, load, capture, navigate, close, on-close.
- CI: pre-existing failures fixed (root meta-package install path,
  tray-stub naming, raco-exe --gui on macOS, .app Resources creation).
- `open-window`/`open-webview` accept `#:devtools?` (macOS:
  setInspectable:; Windows: OpenDevToolsWindow; Linux: not yet).

### Added (Phase 3)
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

## [0.2.0] - 2026-08-14

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

## [0.1.0] - 2026-05-08

### Added
- Local HTTP server for serving web frontend
- Static file serving from `public/` directory
- `raco glaze init <name>` to scaffold new projects
- `raco glaze dev` to start dev server with auto-open browser
- Cross-platform browser opener (Windows/macOS/Linux)
- MIT License
