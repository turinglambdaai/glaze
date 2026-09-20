# Contributing to Glaze

Glaze is a pre-1.0 cross-platform desktop framework. Prefer small changes that preserve application-facing APIs and keep platform details behind the public dispatchers.

## Development Setup

```bash
git clone https://github.com/turinglambdaai/glaze.git
cd glaze
raco pkg install --auto --no-docs --link "$PWD"
```

The repository root is one installable Racket package using `collection 'multi`; the `glaze`, `glaze-cli`, `glaze-doc`, and `glaze-test` collections are installed together.

## Before Opening a Pull Request

Run the platform-independent suite and compile the public entrypoints:

```bash
raco make glaze/main.rkt glaze-cli/cli.rkt scripts/package-entry-smoke.rkt
raco test glaze-test/
```

When your change touches WebView or packaging behavior, also run the relevant verification script on the affected operating system. CI exercises native WebView behavior and package construction on Windows, macOS, and Linux, including a macOS/Racket 9.3 packaging regression test.

### macOS full-occlusion probe

Changes to background WebView scheduling should also be checked from an interactive macOS desktop session:

```bash
racket scripts/macos-occlusion-e2e.rkt
```

The probe opens a WebView with `#:background-active? #t`, covers it with a larger opaque native `NSWindow`, requires AppKit to report the target as fully occluded, and then checks that a JavaScript timer advances for 35 seconds while the cover remains in place. It deliberately fails if it cannot prove full occlusion.

This probe is not part of GitHub Actions. On the hosted `macos-26-arm64` image, ordinary WebView load, capture, navigation, and close checks work, but two attempts to establish occlusion left both windows reporting the same undocumented `occlusionState` value (`8192`) even with an oversized higher-level cover. Because the runner cannot demonstrate the precondition, a green result there would not be a valid regression test for issue #2. Keep that issue open until this probe passes reliably in an environment whose WindowServer reports real occlusion.

## Architecture Rules

Read [`docs/architecture.md`](docs/architecture.md) before moving modules or adding a new capability. In particular:

- normal applications should prefer `(require glaze)`;
- `glaze/main.rkt` is the compatibility-preserving application facade;
- platform-specific modules belong behind `webview/main.rkt`, `tray/main.rkt`, or `sys/main.rkt`;
- do not make platform backends depend on application-level orchestration;
- shared protocols should not be duplicated independently in each backend;
- avoid large directory migrations solely for aesthetics;
- new public behavior should have a platform-independent contract test when possible.

## Code Style

Follow the dominant Racket style already present in the repository. The optional [`fmt`](https://pkgs.racket-lang.org/package/fmt) package can be installed with:

```bash
raco pkg install fmt
```

Do not reformat unrelated files in a functional pull request. Formatting-only churn makes native and lifecycle changes harder to review.

## Tests and Documentation

A change is not complete when only the happy path works. Prefer small regression tests for:

- public facade exports and argument validation;
- lifecycle and cleanup behavior;
- platform-independent protocol logic;
- security boundaries such as path containment and localhost API access;
- package artifacts that actually execute, not merely build successfully.

Update Scribble/API documentation and user-facing examples when a public contract changes. Do not document features that are only planned.

## Pull Requests

Keep each PR focused enough to explain why every changed file is necessary. In the description include the problem, compatibility impact, tests run, and any platform behavior you could not verify locally.

Security issues should follow [`SECURITY.md`](SECURITY.md) instead of being disclosed with exploit details in a public issue.

## Package Structure

| Directory | Purpose |
|---|---|
| `glaze/` | Framework implementation and public facade |
| `glaze-cli/` | `raco glaze` commands |
| `glaze-doc/` | Scribble documentation |
| `glaze-test/` | Regression and contract tests |
| `examples/` | Runnable examples |
| `scripts/` | CI and verification scripts |
