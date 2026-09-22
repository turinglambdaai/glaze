# Security Policy

Glaze embeds native desktop capabilities behind a local HTTP bridge, so security reports are treated as correctness issues, not feature requests.

## Supported versions

Glaze is currently pre-1.0. Security fixes are applied to the latest development/release line. Older 0.x releases may require upgrading rather than receiving a backport.

## Reporting a vulnerability

Please do not publish exploit details, credentials, private keys, license-signing material, or sensitive reproduction data in a public issue.

Prefer GitHub's private **Report a vulnerability** / Security Advisory flow for this repository when it is available. If private reporting is not available, open a minimal public issue stating that you have a security report and need a private contact channel; do not include exploit details in that issue.

A useful report includes:

- affected Glaze version or commit;
- operating system and Racket version;
- affected capability (server/API, WebView, tray, sys, packaging, update, license, etc.);
- minimal reproduction steps;
- expected and observed behavior;
- impact and whether user interaction is required.

## Security boundaries

The project currently treats the following as security-sensitive boundaries:

- the local HTTP API and SSE event stream are loopback-only and support capability-token protection;
- Host and Origin checks are used to reduce localhost/DNS-rebinding and cross-origin abuse;
- static files must remain contained inside the configured public directory;
- native backends must not accept unvalidated application data directly into shells or command strings;
- packaging/signing failures must fail closed rather than silently producing an artifact that claims to be signed;
- update manifests and downloaded artifacts must be treated as untrusted input and verified before replacement;
- offline licensing is a commercial policy mechanism, not a claim of tamper-proof DRM.

Please report any case where implementation behavior violates these boundaries.
