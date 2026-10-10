# Glaze 1.0 Runtime Architecture (RFC)

**Status:** draft, pre-1.0 direction
**Scope:** runtime kernel, bridge protocol, security model, module layout,
and the relationship with Rivet.

This RFC records where Glaze is today, what must be rewritten before 1.0,
and what the target looks like. The short version: **keep the product layer,
the service layer, and the delivery chain; rewrite the runtime kernel.**

## Where we are

Glaze's strengths are real and stay: GUI-first (native windows only, no
browser fallback), the local API + SSE bridge, the service plugins
(filesystem, store, SQL, shell, HTTP, logging, dialogs), inspect/doctor/verify,
real-window CI with screenshots, and the packaging pipeline
(dmg / msi / deb / rpm / AppImage).

The 0.11.1 hardening release closed the acute holes found in the pre-1.0
audit: static-file path traversal (arbitrary file read), cross-site
requests against the loopback bridge (Origin / Sec-Fetch-Site guard,
request size limits), a token-protected bridge by default in `run-app`,
exception-safe `run-app` lifecycle, observable event-bus overflow
(drop-oldest + counters + throttled reports), OpenSSL chosen by capability
instead of PATH accident, and startup-time validation of generated JS
client names.

Those are fixes. They harden the current model; they do not change it. The
model itself still has three structural limits:

1. **The loopback HTTP server is the security boundary.** Host checks,
   tokens, and Origin guards shrink the attack surface, but a TCP port that
   every local process and every web page can reach is the wrong trust
   base for production IPC. Tauri puts the boundary in a versioned async
   message protocol with window-scoped capabilities and a runtime
   authority; the web content never talks to a port.
2. **Lifecycle is implicit.** `run-app` blocks on one window's close; there
   is no app state machine, no custodian-owned resource tree for plugin
   resources, and no story for multi-window, tray-resident, or explicit-quit
   lifecycles.
3. **The bridge is unversioned.** JSON routes + SSE with no wire-protocol
   version, no schema compatibility check, no request cancellation, no
   structured errors, no binary channel, no per-window identity.

## Target architecture

```text
Native Host
├─ owns the OS UI main thread and window lifecycle
├─ WebView2 / WKWebView / WebKitGTK
└─ navigation, download, new-window, permission requests default-deny
        ↕  versioned async protocol (GLZ1)
Racket App Runtime
├─ app state machine
├─ custodian resource tree
├─ typed command schema
└─ lifecycle-aware plugins
```

### Native Host

The host owns the window and everything dangerous. Web content gets
frontend resources through a controlled scheme (`glaze://app/...` in
spirit) instead of a TCP port, and calls the backend through the WebView's
native message handler instead of `fetch`. Navigation, downloads, new
windows, and permission requests are default-deny with explicit grants.

The current pure-Racket FFI hosts (COM vtables on Windows, ObjC on macOS,
GTK/WebKitGTK on Linux) were the bootstrap that proved the product. They
remain supported, but the 1.0 host line ships as small signed prebuilt
shims per platform so Glaze apps never require a C/C++ toolchain and the
FFI surface stops being the long-term maintenance risk. Linux migrates to
GTK 4 / WebKitGTK 6.0 as the primary target (GTK 3 / 4.1 stays as a
compatibility layer for older distros).

### GLZ1: the versioned bridge protocol

Replaces ad-hoc JSON routes + SSE as the production transport:

- protocol version negotiated at connect; compatibility baseline checked
  before the first command;
- request-id / timeout / cancellation on every command;
- typed errors (a closed error taxonomy, not exception text);
- typed events, state, and streams with bounded payloads and explicit
  backpressure;
- per-window capability: every window is an identity; grants attach to the
  window, not to the shared origin;
- binary channel for large payloads.

The HTTP server survives as a **development adapter** (hot reload, curl,
tests). It is no longer the production security boundary and no longer
listens in packaged apps.

### Racket App Runtime

`run-app` becomes a state machine (`starting → ready → running →
stopping → stopped`) instead of "block on one window's close":

- every app owns a custodian; plugins register threads, subprocesses,
  database connections, and timers against the app custodian and get
  deterministic shutdown for free — the Racket-native resource model
  (custodians + eventspaces) becomes the core abstraction instead of a
  per-plugin afterthought;
- multi-window, tray-resident, and explicit-quit lifecycles are expressible:
  windows attach and detach from a running app; app exit is a state
  transition, not a side effect of the last window closing;
- commands are declared with schemas; the schema drives typed client
  generation (JS today, TS declarations), wire validation, and the
  compatibility baseline.

## Module layout

The facade (`glaze/main.rkt`) currently re-exports ~320 identifiers. The
1.0 layout is layered, with a curated stable surface:

```text
glaze/core          app, lifecycle, custodians, capability authority
glaze/bridge        GLZ1 protocol, schema, typed clients
glaze/window        windows, webview handles, window state
glaze/services      filesystem, store, sql, shell, http, log, dialogs, tray
glaze/distribution  build, sign, update, platform packaging
glaze/devtools      inspect, doctor, verify, dev server
glaze/experimental  anything unfrozen
```

The stable facade keeps the 20–40 entry points real apps touch daily;
everything else is reachable through the layer modules. `experimental/`
never freezes by accident. Error types are part of the public contract;
internal exception text never reaches the page (already true since 0.11.1
for the 500 path).

## Relationship with Rivet

Glaze and Rivet are two renderers over one application model:

- **Glaze** — WebView renderer + web frontend SDK: fastest path to a
  product, web ecosystem, visual consistency, AI-friendly verification.
- **Rivet** — native renderer + Swift/C++/Kotlin SDK: platform-native
  experience, deep system integration, first-party controls.

Neither should depend on the other. The shared part — app identity and
manifest, typed schema, wire encoding, lifecycle semantics, capability
authority, distribution/update/signing, diagnostics — is a neutral third
layer (`racket-app-core` in spirit). Extracting it means one golden-vector
test suite and one compatibility baseline serve both projects, instead of
two teams separately rewriting packaging, update, signing, permissions,
and lifecycle.

Near-term coordination (no big-bang extraction): Glaze's GLZ1 design
absorbs the parts Rivet already proved — schema, typed RPC, event/state,
cancellation, compatibility baseline, cross-language golden vectors —
extended with what a WebView bridge needs (structured errors, streams,
binary, floats/objects as first-class JSON-compatible values). The
concrete extraction proposal lives as an issue on the Rivet tracker.

## 1.0 gate

A 1.0 freeze requires, in order:

1. the new kernel running end-to-end on macOS (window, resource tree,
   typed invoke, event, close, package — one vertical slice);
2. Windows and Linux ports passing the same protocol golden vectors and
   lifecycle tests;
3. protocol fuzzing and a long-run resource-leak soak;
4. minimum-and-latest supported Racket versions and both architectures in
   CI, with real install/upgrade tests on all three platforms;
5. an external security review of the host boundary and GLZ1.

## Migration order

1. ~~0.11.1 hardening (done) — the security floor.~~
2. Freeze product scope; no new plugins until the kernel lands.
3. GLZ1 protocol spec + golden vectors (shared with Rivet where shapes
   coincide).
4. macOS vertical slice of the app state machine + host scheme.
5. Windows/Linux ports; HTTP dev adapter kept for the dev loop.
6. Facade curation (`core/bridge/window/services/distribution/devtools`,
   `experimental/`).
7. The 1.0 gate above.
