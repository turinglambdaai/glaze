# Publishing Glaze to winget

Glaze uses `TuringLambda.Glaze` as its Windows Package Manager identifier.
The release workflow publishes a self-contained x64 MSI and SHA-256 file for
every annotated release tag. `.github/workflows/winget.yml` then uses only the
`-windows-x64.msi` asset for package updates.

The first submission is a one-time operation:

1. Generate and validate the seed manifests under
   `packaging/winget/TuringLambda.Glaze/<version>/` from the released MSI.
2. Configure the repository secret `WINGET_TOKEN` with a classic GitHub PAT
   that has the `public_repo` scope.
3. Manually dispatch the `winget` workflow. Its bootstrap job is idempotent:
   it exits without opening a duplicate PR after the package exists upstream.

After Microsoft merges the initial package PR, each GitHub release triggers
`winget-releaser` to open the version-update PR automatically.

The manifest folder and `PackageIdentifier` must always agree. The MSI is a
per-machine x64 package, uses a stable UpgradeCode derived from
`TuringLambda.Glaze`, and supports silent install/uninstall through standard
Windows Installer switches.
