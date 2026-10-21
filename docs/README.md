# Glaze documentation map

This directory has one owner for each durable decision. New documents must link from this map and must not create a second source of truth for an existing subject.

## Architecture and governance

- [Current architecture](architecture.md): the runtime, transport, trust, module, and dependency boundaries that are true today.
- [Glaze 1.0 plan](1.0-plan.md): the active sequence, gates, evidence, work ownership, and next implementation handoff. Delete it after the 1.0 gates close.
- [API stability](api-stability.md): public-module tiers, compatibility rules, and the exact export gate.
- [AI implementation handoff](agent-handoff.md): the one-slice execution, ownership, validation, and stop rules used by ZCode and other agents.

## Developer and product contracts

- [Getting started](getting-started.md): canonical install, scaffold, typed route, schema, native verification, and build tutorial.
- [Agent-native workflow](agent-native.md): project inspection, diagnosis, editing, and native-window verification.
- [GUI-first contract](gui-first.md): why application startup requires a native WebView and never falls back to a browser tab.
- [Releasing](RELEASING.md): framework release procedure and provenance requirements.

The generated HTML site under `docs/index.html` is product-facing material. The Racket API reference lives under `glaze-doc/scribblings/`. Durable engineering decisions belong in the Markdown owners above, then user-facing material should link to or summarize them.
