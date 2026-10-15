# AI implementation handoff

This is the execution contract for ZCode and any other implementation agent.
It explains how to continue Glaze without recovering architecture from chat
history or widening a task while coding. The active work item itself lives only
in [the 1.0 plan](1.0-plan.md), under **Next implementation handoff**.

## Source-of-truth order

When instructions disagree, use this order:

1. `AGENTS.md` for repository-wide invariants and validation obligations;
2. `docs/architecture.md` for current dependency and trust boundaries;
3. `docs/api-stability.md` for public compatibility decisions;
4. `docs/1.0-plan.md` for the one active implementation slice;
5. tests for executable behavior;
6. historical RFCs and chat history for rationale only.

Do not create a second roadmap, architecture description, API list, or active
work queue. Amend the owner above instead.

## One-slice protocol

Before editing, copy the active handoff into the working notes and identify:

- **invariant**: behavior that must remain true;
- **owner files**: the smallest files the slice may edit;
- **forbidden files**: adjacent owners that must remain untouched;
- **characterization**: the focused test that proves current behavior;
- **exit evidence**: exact commands that must pass;
- **rollback unit**: the files that can be reverted together without leaving a
  half-migrated import graph.

Implement only that slice. A discovered defect outside it becomes a proposed
next handoff unless it prevents the current invariant from being preserved.
Never combine extraction, feature work, public API changes, and formatting in
one slice.

## Boundary rules

- Public paths remain stable during G2. New implementation modules go under
  `glaze/private/` or `glaze-cli/private/`; the existing public owner imports
  and, where required, re-exports them.
- Implementation modules point inward. They do not import `glaze`, reviewed
  layer facades, CLI dispatchers, or another aggregation module.
- Native and HTTP carriers share command semantics, schema generation, static
  resource policy, and error vocabulary. Carrier adapters may only translate
  delivery mechanics.
- Platform backends implement the documented backend contract. Shared code
  does not branch on private platform handles.
- A schema baseline and an export snapshot are release contracts. Never update
  either automatically to make a failing check green.
- HackDigest is a consumer canary, not a place to prototype framework
  internals. Consumer changes should be configuration, explicit imports, or
  acceptance evidence unless a product behavior change is separately approved.

## Validation ladder

Run validation from narrowest to widest:

1. `raco make` on every changed Racket module;
2. direct tests for the extracted private boundary;
3. affected adapter/platform suites;
4. `raco test glaze-test/`;
5. `raco make glaze/main.rkt glaze-cli/cli.rkt`;
6. `git diff --check`;
7. when runtime, schema, packaging, or public imports are affected, run the
   HackDigest backend, frontend, TypeScript, and schema checks listed in the
   active handoff.

An OS-specific slice is not complete merely because it compiles elsewhere.
Record the unrun platform job as missing evidence, not as a pass.

## Completing a slice

Update the progress paragraph and replace **Next implementation handoff** with
exactly one bounded successor. Record file ownership and commands there. Update
`CHANGELOG.md` for user-visible or architectural changes. If the next task
requires a different stream, stop after leaving the repository green; do not
start it opportunistically.

Stop and request a design decision when a task requires a public removal,
schema break, protocol version change, trust-boundary relaxation, new platform
dependency, or a HackDigest behavior change. Those are product decisions, not
implementation details.
