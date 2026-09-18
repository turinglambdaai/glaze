# Releasing Glaze

This checklist keeps a Glaze release reproducible without putting signing credentials in the repository.

Glaze is still pre-1.0, so releases should remain conservative: stabilize and verify existing public behavior before adding release-only features.

## 1. Prepare the release commit

Before tagging a release:

1. update the root `info.rkt` version;
2. update `CHANGELOG.md` with user-visible changes and compatibility notes;
3. verify `README.md`, `README.zh-CN.md`, Scribble documentation, and examples describe behavior that actually exists;
4. make sure no private keys, certificates, notary profiles, generated installers, or customer license files are committed;
5. ensure the release commit is fully reviewed and CI is green.

Racket version strings must follow the package manager's accepted version syntax; use the same value consistently in package metadata and release notes.

## 2. Required CI gates

The release commit should pass the repository CI without skipped failures:

- compile public entrypoints on Windows, macOS, and Linux;
- run the full `glaze-test/` suite on all three platforms;
- run native WebView end-to-end tests on all three platforms;
- execute a final packaged application, not only the build command;
- build platform installers/distribution archives;
- verify the macOS bundle signature used by CI;
- run the dedicated macOS/Racket 9.3 packaging regression;
- create a filtered Racket source package, install that archive from scratch, and verify `(require glaze)` plus `raco glaze`.

A passing checkout build is not sufficient if the source archive or packaged executable fails independently.

## 3. Build commercial distribution artifacts

The CI artifacts are smoke-test artifacts. Production releases should be rebuilt with the publisher's real signing identity where the platform supports signing.

### macOS

Use a Developer ID Application identity and hardened runtime:

```bash
raco glaze build \
  --name MyApp \
  --version 1.2.3 \
  --installer \
  --sign "Developer ID Application: Example Corp (TEAMID)" \
  --notarize my-notary-profile
```

Then verify the result independently:

```bash
codesign --verify --strict --verbose=2 dist/MyApp.app
spctl --assess --type execute --verbose=2 dist/MyApp.app
```

When a DMG is shipped, verify the notarization/stapling status of the final artifact as well as the app bundle.

### Windows

Use a real code-signing certificate through `signtool` and an RFC-3161 timestamp server:

```bash
raco glaze build \
  --name MyApp \
  --version 1.2.3 \
  --installer \
  --sign <certificate-thumbprint-or-subject>
```

Verify both the executable and installer with the Windows signing tools before publication. Do not treat an unsigned fallback archive as equivalent to a signed commercial installer.

### Linux

Glaze can produce an AppImage when `appimagetool` is available, otherwise a portable archive fallback. Linux has no single universal code-signing mechanism in the current Glaze build API; distributors should use the signing/verification mechanism appropriate to their chosen channel.

## 4. Create the Racket source package

Racket packages are normally distributed as source. From the checkout parent directory:

```bash
raco pkg create --source --format zip glaze
```

Install the resulting archive in a clean Racket environment before publishing it:

```bash
raco pkg install --auto --no-docs glaze.zip
racket -e '(require glaze)'
raco glaze help
```

CI performs the equivalent source-package smoke test so repository-only files or local links cannot accidentally become hidden release dependencies.

## 5. Security review

Before publishing, re-check the boundaries documented in [`../SECURITY.md`](../SECURITY.md):

- localhost API/SSE authentication and origin/host checks;
- static-file containment;
- command/subprocess argument construction;
- update artifact verification;
- signing/notarization failure behavior;
- accidental logging or packaging of tokens, credentials, private keys, or customer data.

Any unresolved vulnerability with material impact should block the release.

## 6. Publish

After the exact release commit passes all gates:

1. create the release tag from that commit;
2. publish release notes from `CHANGELOG.md`;
3. attach only verified artifacts;
4. update the Racket package catalog/source reference as appropriate;
5. verify installation from the public release source on a clean machine or clean Racket installation;
6. keep the previous known-good release available for rollback.

Do not rebuild an artifact after tagging and publish it under the same version without documenting that the bits changed. A release version should identify one reproducible source state.

## 7. Post-release smoke checks

After publication, perform at least one clean install per supported desktop platform and verify:

- application startup;
- native WebView creation;
- JSON API + SSE bridge;
- shutdown/cleanup;
- one native capability such as tray or clipboard;
- the published package/installer launches without depending on the source checkout.

Record any platform-specific release regression as an issue with the release version, OS version, Racket version, and reproduction steps.
