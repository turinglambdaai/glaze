# Agent-native Glaze workflow

**Human-first. Agent-native. Local by design.**

Glaze projects remain ordinary Racket and web projects. The agent contract
adds reliable discovery and verification; it does not introduce a second UI
language or a browser-only development mode.

## The loop

```text
raco glaze inspect --json
raco glaze doctor --json
# edit main.rkt and/or public/
raco glaze verify
raco glaze build
```

- `inspect --json` reports the versioned project contract, editable sources,
  generated paths, native backend, evidence types, and whether each expected
  file exists.
- `doctor --json` reports package ownership, collection resolution, WebView
  readiness, actionable problems, and an overall `usable` value. It is
  read-only; `--json` cannot be combined with `--fix`.
- `verify` runs the project's checked-in `verify.rkt`. The generated verifier
  waits for the real system WebView, checks page state and URL, captures a PNG,
  and exits nonzero on failure.

## Edit boundaries

- Put Racket routes, events, and window behavior in `main.rkt`.
- Put HTML, CSS, JavaScript, and frontend assets in `public/`.
- Keep app-specific acceptance checks in `verify.rkt`.
- Treat `dist/` as generated output.

The generated `AGENTS.md` carries these rules with the project, so a local
coding agent can orient itself without scraping prose documentation or guessing
which output is safe to edit.
