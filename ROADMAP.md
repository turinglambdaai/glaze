# Glaze Roadmap

Glaze is a pre-1.0 project. This roadmap is intentionally small: it describes the next architectural steps without promising a large plugin ecosystem or a full desktop platform rewrite.

## v0.x — Stabilize

The current priority is to make the framework predictable for application authors and maintainers.

- stabilize application lifecycle semantics around `run-app`, window close, browser fallback, and shutdown
- keep `(require glaze)` as the recommended application-facing facade
- document which modules are public, internal, platform-specific, or experimental
- tighten argument validation and error behavior where contracts are currently implicit
- keep examples minimal, runnable, and aligned with recommended APIs
- add regression tests around public API imports, platform-independent behavior, events, and lifecycle
- keep Windows, macOS, and Linux backend contracts aligned
- improve packaging and documentation without introducing avoidable breaking changes

## Next

Once the current lifecycle and API surface are better defined, the next layer of work can focus on communication and common desktop capabilities.

- define a clearer JS/Racket message bridge on top of the existing HTTP/SSE model
- make the event model more explicit and consistent across runtime and UI integration
- add notification/storage capabilities behind the same public capability boundary
- improve packaging metadata, signing workflows, and project configuration
- continue consolidating generated/scaffolded applications around the public facade

These changes should remain incremental. Existing HTTP JSON routes and SSE behavior should not be removed merely to introduce a new abstraction.

## Later

Possible longer-term work, after the core contracts are stable:

- plugin SDK with explicit capability and version boundaries
- development-time hot reload
- richer project templates
- ecosystem integrations for additional native capabilities
- reusable capability packages such as filesystem, serial, CAN, or application-specific integrations

These are directions, not commitments for the current release line.

## Explicitly Not in the Current Stabilization Pass

The current architecture work does not attempt to:

- reproduce Electron feature-for-feature
- bundle a custom browser runtime
- introduce a large JavaScript build stack
- rewrite all native backends
- implement a complete RPC framework
- implement a plugin system before the public API and lifecycle are stable
