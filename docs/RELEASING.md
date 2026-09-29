# Releasing Glaze

Glaze uses two equivalent version forms: `info.rkt` carries the canonical
Racket package version (for example `0.7`), while `release-version`, Git tags,
the changelog, and GitHub Releases use three-component SemVer (`0.7.0`).

1. Move the pending changelog entries into a dated release section.
2. Update both version bindings and the README release badges.
3. Merge the fully green release-preparation pull request into `main`.
4. Create and push an annotated `vMAJOR.MINOR.PATCH` tag on that exact commit.

The tag workflow verifies that the commit belongs to `main`, runs the complete
package test suite, builds the Scribble manual, creates the Racket source ZIP,
installs that exact ZIP into a fresh package scope, and publishes the archive,
checksum, and changelog notes as a GitHub Release.
