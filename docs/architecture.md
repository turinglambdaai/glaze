# Glaze Architecture

Glaze is a Racket-first desktop application framework that combines a web UI with a Racket runtime and native desktop capabilities.

This document describes the architecture that exists today and the direction the project should preserve while it evolves. It is not a proposal to rewrite the repository into a new directory structure.

## Goals

- keep the application-facing API small and easy to discover
- preserve a clear dependency direction from application code toward lower-level capabilities
- isolate Windows, macOS, and Linux implementation details behind dispatch modules
- keep native surface area small and explicit
- make behavior testable without requiring callers to understand backend internals
- preserve good Racket development ergonomics, including simple `require`, REPL use, macros, and ordinary modules
- prefer incremental compatibility-preserving changes over architecture-driven rewrites

## Non-goals

The current stabilization work is not trying to provide:

- Electron feature parity
- a bundled browser runtime or custom renderer
- a complete typed RPC framework
- a large plugin ecosystem
- hot reload as a framework-level subsystem
- a large frontend toolchain
- a rewrite of all native backends

Those may be explored later when the current public contracts are stable enough to support them.

## Current Layers

The repository is one Racket package with multiple collections. The runtime architecture can be understood as the following layers:

```text
Application
    |
    v
Public API / Facade
    |
    v
Runtime and shared capabilities
    |
    v
Platform dispatch
    |
    v
Native backends
```

The mapping to existing code is:

```text
Application
    |
    v
`glaze/main.rkt`
Public facade exported by `(require glaze)`
    |
    +---------------------------+
    |            |              |
    v            v              v
Runtime       Capabilities    Tooling
`app.rkt`     `webview/main`  `build.rkt`
`server.rkt`  `tray/main`     `update.rkt`
`api.rkt`     `sys/main`      `glaze-cli/`
`events.rkt`  dialogs/etc.
    |            |
    +------+-----+
           v
Platform-specific backends
`webview/webview-{windows,macos,linux,stub}.rkt`
`tray/tray-{windows,macos,linux,stub}.rkt`
`sys/sys-{windows,macos,linux,stub}.rkt`
```

### Application

Application code should normally depend on the `glaze` facade rather than individual implementation modules.

Recommended:

```racket
(require glaze)
```

Direct imports such as `glaze/webview/webview-windows` or `glaze/tray/tray-macos` couple an application to implementation details and are not the recommended application-level API.

### Public API / Facade

`glaze/main.rkt` is the current facade. It re-exports the major framework surfaces so applications can use one `require` path.

The facade is intentionally compatibility-oriented today: it exports a broad set of existing APIs instead of hiding them immediately. During 0.x stabilization, narrowing the facade should happen only with deprecation and migration planning.

### Runtime

The runtime composes capabilities into an application lifecycle:

- `app.rkt` owns the high-level `run-app` flow
- `server.rkt` serves static assets, JSON routes, and framework endpoints
- `api.rkt` and `api-macros.rkt` define request/response routing
- `events.rkt` provides backend-to-frontend event delivery over SSE

`app.rkt` depends on the server, events, update support, and the public WebView dispatcher. This is an expected high-level dependency direction.

### Capabilities

Capability modules expose OS-facing functions without making application code select a backend:

- `webview/main.rkt`
- `tray/main.rkt`
- `sys/main.rkt`
- `dialogs.rkt`
- `deeplink.rkt`
- `autolaunch.rkt`
- `browser.rkt`

The WebView, tray, and sys modules already follow the same useful pattern: a platform-independent API dispatches lazily to the backend selected by `(system-type 'os)`.

### Platform Backends

Platform backend modules are implementation details. They use Racket FFI, Objective-C FFI, subprocesses, or operating-system APIs to satisfy the capability contract.

These modules should not depend on `app.rkt` or other application-level orchestration modules. Backend modules may depend on small shared protocols or lower-level utilities needed to implement their contract.

## Dependency Rules

The project should evolve toward these rules without requiring a large file move:

1. **Applications depend on the public facade.**
   New examples and generated application templates should prefer `(require glaze)`.

2. **The public facade may depend on runtime and capability modules.**
   `glaze/main.rkt` is allowed to re-export stable application-facing functionality.

3. **Runtime orchestration may depend on capabilities.**
   For example, `run-app` may depend on `server.rkt`, `events.rkt`, and `webview/main.rkt`.

4. **Capability dispatchers may depend on shared lower-level protocols, but not application orchestration.**
   `webview/main.rkt` depending on the tray menu protocol is acceptable because the protocol is a shared data model used to build native menus. A dependency on `app.rkt` would reverse the intended direction.

5. **Platform backends must not become application APIs.**
   They should remain behind dispatcher modules and may change as native implementation details require.

6. **Shared protocols belong below their consumers.**
   If multiple capabilities need the same types or protocol definitions, they should live in a small lower-level module rather than one capability importing another capability's full implementation.

7. **Avoid cycles.**
   New code should not introduce cycles between runtime, capability dispatchers, and backend modules. If two modules need the same definition, extract only that shared definition rather than merging unrelated responsibilities.

8. **Prefer facade and tests before file moves.**
   When an internal/public boundary is unclear, first establish it in exports, documentation, tests, and comments. Move files only when the compatibility and maintenance benefit is clear.

## Public vs Internal API

The repository did not previously have a formal stability classification for every module. The following classification records the intended boundary for new development.

### Public

Preferred application-facing entry point:

- `glaze` (`glaze/main.rkt`)

The following module paths also expose useful APIs today and remain supported for compatibility, but application documentation should prefer the facade unless a focused import is useful:

- `glaze/app`
- `glaze/server`
- `glaze/api`
- `glaze/api-macros`
- `glaze/events`
- `glaze/webview/main`
- `glaze/tray/main`
- `glaze/sys/main`
- `glaze/dialogs`
- `glaze/deeplink`
- `glaze/autolaunch`
- `glaze/browser`
- `glaze/build`
- `glaze/update`
- `glaze/license`

This is a compatibility statement, not a promise that every exported binding already has a 1.0-stable contract.

### Internal implementation

Modules that implement framework mechanics but should not be imported by normal application code include platform backends and implementation-specific helper modules.

Examples:

- `glaze/webview/webview-windows`
- `glaze/webview/webview-macos`
- `glaze/webview/webview-linux`
- `glaze/webview/webview-stub`
- `glaze/tray/tray-windows`
- `glaze/tray/tray-macos`
- `glaze/tray/tray-linux`
- `glaze/tray/tray-stub`
- `glaze/sys/sys-windows`
- `glaze/sys/sys-macos`
- `glaze/sys/sys-linux`
- `glaze/sys/sys-stub`

Tests may import these modules when they explicitly test a backend contract. Applications should not.

### Shared protocol

`glaze/tray/tray-protocol.rkt` is currently a shared protocol/data-model module rather than a native backend. WebView menu support reuses its menu definitions. Although it is re-exported through the tray public API, its main architectural role is lower-level shared data.

If menu definitions later become a broader application-wide concept, they can be promoted into a neutral shared module in a separate compatibility-focused change.

### Platform-specific

Any module named for an operating system is platform-specific by definition. Its implementation and FFI details are free to differ as long as the public dispatcher contract remains consistent.

### Experimental

Glaze is pre-1.0, so newly introduced APIs may be marked experimental in documentation before they are made part of the stable facade. Experimental status should be explicit; it should not be inferred merely because an API lives in a separate file.

## Current Dependency Observations

The current WebView, tray, and sys implementations already have a sound dispatch shape:

- the public dispatcher selects the backend lazily
- applications do not need to select an operating system implementation
- unsupported native capabilities can report `#f` or use a stub/fallback behavior

A small coupling exists where `webview/main.rkt` imports only `menu?` from `tray/tray-protocol.rkt`. This is not a cycle and does not pull in the tray backend, but it shows why shared protocol/types should remain lightweight.

The repository therefore does not need a large platform-layer rewrite to make architectural progress. The higher-value near-term work is to stabilize lifecycle semantics, public contracts, tests, and documentation.

## Testing Boundaries

Tests should be divided conceptually into three groups:

- **facade/API tests**: prove `(require glaze)` exposes the documented application surface
- **platform-independent tests**: routing, argument validation, events, lifecycle helpers, parsing, and other logic that can run on all hosts
- **backend/e2e tests**: validate the OS-specific implementation behind the dispatcher

The existing CI already runs the test suite on Windows, macOS, and Linux and has a separate real-window WebView e2e job. That structure should be preserved.

## Evolution Strategy

Changes should normally follow this order:

```text
Bug / correctness
    >
API inconsistency
    >
dependency problem
    >
missing regression test
    >
documentation gap
    >
directory aesthetics
```

A future `private/` or `internal/` directory may be useful, but moving working FFI files solely for visual cleanliness is not a current priority. A documented boundary plus a tested facade gives the project most of the maintenance benefit with much lower compatibility risk.
