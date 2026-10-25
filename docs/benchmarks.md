# Framework performance baseline

This baseline measures the real native-transport stack — the GLZ1 bridge
dispatch core, typed-route validation, stream registration, and transport
startup — through the same `dispatch-bridge` entry the platform carriers
use, instead of a detached codec microbenchmark. One command produces one
JSON report:

```bash
racket scripts/measure-baseline.rkt            # human-readable
racket scripts/measure-baseline.rkt --json     # machine report
racket scripts/measure-baseline.rkt --samples 15
```

## What is measured

The report carries `schema_version` (1), `platform`, `architecture`,
`configuration`, and `racket-version`, so results from different execution
contexts are never compared as one series. The groups:

- `transport_startup`: N samples (default 7) of a fresh
  `start-native-transport` + `shutdown!` cycle — route compilation,
  bootstrap JavaScript generation, and stream/event wiring. Each sample is
  a full lifecycle; startup is itself one of the measured costs. Median,
  min, and max are recorded.
- `invoke.ping` / `invoke.typed-echo`: 1,000 sequential round trips each
  after a warm-up phase (plain and typed-validated routes), reporting
  `iterations`, `total_ms`, and `us_per_operation`. Every timed operation
  validates its result, so a fast but incorrect run fails instead of
  producing a number.
- `stream.stream-accept`: 200 streaming-route dispatches. A streaming
  invoke returns after dispatch and stream registration — the frames are
  framed and delivered on the transport's own threads, whose end-to-end
  latency (ordered chunks, cancel, UTF-8 draining) is the conformance
  suite's evidence, not this group's.
- `resources`: two equal 2,000-invoke bursts with a `collect-garbage`
  between them. A leak shows as continued heap growth into the second
  burst; a healthy stack plateaus. Thread and handle cleanup is owned by
  the deterministic-teardown conformance scenario (`native-transport-shutdown!`
  joins its threads, is idempotent, and freezes the stats), so this group
  records heap only.

`heap bytes` are Racket heap (`current-memory-use` after GC), not OS RSS.

Packaged-application size and launch survival are measured separately by
`raco glaze measure size [--budget <file>]` and
`raco glaze measure startup`, which gate `dist/` artifacts mechanically
(see the release workflow).

## Recorded baseline (informational)

Machine: Apple M-series laptop (aarch64), macOS, Racket 9.3, development
configuration. Recorded 2026-10-25 from
`racket scripts/measure-baseline.rkt --samples 7`:

- transport startup: ~0.1 ms median per start/shutdown cycle
- invoke ping: ~25–31 us/op (1,000 iterations)
- invoke typed-echo: ~29–32 us/op (1,000 iterations)
- stream accept: ~27–30 us/op (200 iterations)
- resources: heap growth between the two 4,000-invoke bursts ~12 KB
  (plateau — no leak signal)

These numbers are a reference point for regression investigation. They are
NOT release thresholds and NOT performance claims.

## Comparing results and CI behavior

Do not treat absolute timings from shared GitHub-hosted runners as
pass/fail limits; host load, CPU generation, and Racket version move
results independently of Glaze code. To compare meaningfully:

- compare the same platform, architecture, configuration, and Racket
  version;
- run several samples and compare medians, not single runs;
- establish release thresholds only on dedicated hardware with history.

The CI records one baseline JSON per runner and revision as informational
evidence; the measured values have no pass/fail thresholds, so runner
variance cannot reject a pull request. Once enough history exists on
stable hardware, selected metrics can be promoted to guarded thresholds
without redesigning the harness.
