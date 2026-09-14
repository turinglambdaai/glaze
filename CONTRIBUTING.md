# Contributing to Glaze

## Development Setup

```bash
git clone https://github.com/turinglambdaai/glaze.git
cd glaze
raco pkg install --auto --link "$PWD"
```

(The repo root is one single Racket package — this installs the library,
the `raco glaze` CLI, and the docs in one step. `"$PWD"` is needed because
`raco pkg install` requires the source path to end in the package name.
After pulling changes, refresh with `raco pkg update --link "$PWD"`.)

## Running Tests

```bash
raco test glaze-test/
```

## Code Style

- Follow standard Racket conventions
- Use `raco fmt` for formatting
- Add tests for new features
- Update Scribble documentation

## Pull Requests

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests
5. Submit a PR with a clear description

## Package Structure

The repo root is a single installable package; each top-level directory is a
Racket collection:

| Directory | Purpose |
|-----------|---------|
| `glaze/` | Core implementation (collection `glaze`) |
| `glaze-cli/` | `raco glaze` commands |
| `glaze-doc/` | Scribble documentation |
| `glaze-test/` | Tests |
| `examples/` | Runnable examples (not compiled by setup) |
