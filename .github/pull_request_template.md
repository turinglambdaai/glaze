## Summary

Describe the user-visible or maintenance problem this PR solves.

## Validation

- [ ] `raco make glaze/main.rkt glaze-cli/cli.rkt`
- [ ] `raco test glaze-test/`
- [ ] Public API changes are documented, or this PR does not change the public API
- [ ] Platform-specific behavior is behind the existing dispatcher boundary
- [ ] Packaging changes were exercised on the affected platform(s)
- [ ] Security-sensitive changes avoid shell interpolation and keep loopback capability boundaries intact

## Compatibility

Call out any behavior change that existing Glaze applications may observe. Prefer additive changes during the 0.x stabilization period.
