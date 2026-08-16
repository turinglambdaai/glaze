# Contributing to Glaze

## Development Setup

```bash
git clone https://github.com/turinglambdaai/glaze.git
cd glaze
raco pkg install --auto --link ./glaze-lib ./glaze-cli ./glaze-doc ./glaze-test
```

(End users don't need any of this — `raco pkg install --auto glaze` from the
Racket package catalog installs everything, via the `glaze` metapackage.)

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

Glaze follows the standard Racket multi-package layout:

| Package | Purpose |
|---------|---------|
| `glaze` | Metapackage |
| `glaze-lib` | Core implementation |
| `glaze-cli` | `raco glaze` commands |
| `glaze-doc` | Scribble documentation |
| `glaze-test` | Tests |
