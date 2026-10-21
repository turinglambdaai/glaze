# Getting started: your first Glaze desktop app

This is the **canonical** newcomer journey: installation, scaffolding, a typed Racket API, its JavaScript caller, schema review, real-window verification, and a build. Other introductions should link here rather than duplicate these steps.

## 1. Install Glaze and check your platform

Install **Racket 9.0+ (CS)** with `raco` available:

```sh
racket --version
raco pkg install --auto glaze
raco glaze help
```

Expected: `raco glaze help` lists commands without starting a window. To use the source checkout instead of the package catalog, run `raco pkg install --auto --link "$PWD"` from the repository root.

Glaze renders in a **native desktop WebView**. Windows needs [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/consumer/) (the bundled loader DLL is not the runtime); macOS provides WKWebView but requires an interactive graphical session; Linux needs GTK 3, WebKitGTK and a graphical session (Xvfb for headless CI). Startup fails with the native error and repair guidance instead of substituting Chrome/Edge/Safari. `doctor` can diagnose installation prerequisites but does **not** guarantee an available graphical session.

## 2. Create a project

```sh
raco glaze init myapp
cd myapp
raco glaze inspect --json
raco glaze doctor --json
raco glaze schema check --json
```

Expected: `inspect` lists the editable and generated files, `doctor` reports prerequisite readiness, and the generated empty-route schema matches its baseline. The exact scaffold is:

```text
myapp/
├── main.rkt           # exported api; module+ main runs the app
├── glaze.rktd         # schema module, exported binding and baseline location
├── glaze-schema.json  # deterministic application API contract
├── AGENTS.md          # project-local edit and validation boundaries
├── verify.rkt         # independent native title/URL/PNG check
└── public/
    └── index.html     # editable HTML/CSS/JS page
```

`glaze.rktd` declares the `main.rkt` module and exported `api` route list. Keep application startup in `module+ main`, so loading the API for schema checks does not start the GUI.

## 3. Add a typed Racket route

Replace `main.rkt` with:

```racket
#lang racket/base

(require racket/runtime-path glaze)
(define-runtime-path public "public")

(define-api-routes api
  [(POST "api/greet")
   (greet [name GString "World"])
   (hasheq 'message (string-append "Hello, " name "!"))])
(provide api)

(module+ main
  (run-app #:public-dir public
           #:api api
           #:title "myapp"))
```

`GString` is a Glaze type descriptor: it checks `name` as a string at runtime **and** records the parameter as a string in the generated GLZ1 application schema. Unlike a plain `string?` predicate, it produces a typed command contract. The same declaration creates the client binding `glaze.api.greet`; there is no manual API-client mapping.

## 4. Call the route from your page

Replace `public/index.html` with:

```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Glaze App</title></head>
<body>
  <h1>My first Glaze app</h1>
  <button id="greet">Greet Ada</button>
  <output id="reply" aria-live="polite">Press the button.</output>
  <script src="/glaze/api.js"></script>
  <script>
    document.getElementById("greet").addEventListener("click", async () => {
      const reply = document.getElementById("reply");
      try {
        const result = await glaze.api.greet({name: "Ada"});
        reply.textContent = result.message;
      } catch (error) {
        reply.textContent = "Request failed: " + error.message;
      }
    });
  </script>
</body>
</html>
```

Expected: clicking **Greet Ada** displays **Hello, Ada!**.

The generated JavaScript client supports native GLZ1 WebView messaging and the HTTP development adapter. During 0.x, the generated `run-app` defaults to `http` transport **inside a native WebView**. Packaged products can explicitly use `#:transport 'native` on Windows, macOS, and Linux until the 1.0 default switches. Neither transport permits browser-only application fallback.

## 5. Review the application schema

```sh
raco glaze schema check --json
```

Expected after adding `greet`: a compatible addition against the empty scaffold baseline (without silently rewriting the file). Once this new route is an intentional public application contract, update and check the baseline:

```sh
raco glaze schema write
raco glaze schema check --json
```

Review and commit the change to `glaze-schema.json`. Never rewrite the baseline merely to hide a breaking change. If loading fails, verify the `api` export and `glaze.rktd` settings.

## 6. Open and verify a real window

```sh
raco glaze dev
# Close the application window before continuing.
raco glaze verify
```

Expected: `dev` executes the actual `main.rkt` and opens a native desktop window. The generated `verify.rkt` independently loads a standard **Glaze App** page in a real native window, checks title and URL, captures a nonempty PNG, and fails with a nonzero exit code when verification does not succeed. It does not itself assert that the greeting button worked; extend it for product-specific acceptance.

When the window cannot open, inspect `raco glaze doctor --json`, platform runtime installation, and the underlying WebView error. Local verification does not replace native CI e2e on Windows, macOS and Linux.

## 7. Build

```sh
raco glaze build --name myapp
```

Expected: a distributable under `dist/`. For an installer use `--installer` with a reviewed version, publisher and stable `--identifier`. Missing installer tooling can trigger an archive **packaging format** fallback with a warning, but the packaged application still needs its real native WebView. Production shipments require platform smoke checks and signing/notarization when applicable.

## Explore further

- [Counter example](../examples/counter/): more routes, state and events.
- [Agent-native workflow](agent-native.md): inspect, doctor, schema and verify.
- [Current architecture](architecture.md): native transport and compatibility adapter.
- [Release procedure](RELEASING.md): release evidence and provenance.
- [Contribution guide](../CONTRIBUTING.md): framework development.
