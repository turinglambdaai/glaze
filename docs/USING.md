# Glaze adoption and support

**English** · [简体中文](USING.zh-CN.md)

## When to use it

Choose Glaze for a Racket backend and a shared HTML/CSS/JS interface inside native system WebViews. A real desktop window is mandatory; there is no external-browser fallback. Product data/permissions and service policy remain application-owned.

## Requirements and maturity

Racket CS 9.0+. Windows needs WebView2 Runtime, macOS needs an interactive WKWebView session, and Linux needs GTK 3/WebKitGTK plus a graphical session. Native GLZ1 exists on all desktops; the 0.x run-app default remains the HTTP adapter in a native WebView.

## One useful verification

Follow the typed-route tutorial, review schema changes and verify an observable action in your own packaged window. The generated title/URL/screenshot probe is a starting point, not proof of your product flow. Check focus, IME, scale, accessibility, dialogs and cancellation on every supported WebView.

## Reading path

1. [First application](getting-started.md)
2. [Documentation map](README.md)
3. [API stability](api-stability.md)
4. [GUI-first contract](gui-first.md)
5. [Releasing](RELEASING.md)

Technical references retain one normative meaning. Chinese onboarding explains and links to that reference rather than creating a second protocol.

## Upgrades, data and support

Record the package versions and platforms your application actually tests. Read CHANGELOG and compatibility contracts before upgrading, test user-data migration on copies and retain a recoverable version. A library does not supply your product’s database backup, publisher identity, refunds, account recovery or privacy policy. Example customer/offer identifiers and amounts are fixtures, not live offers.

Use [Issues](https://github.com/turlamai/glaze/issues) in English or Chinese. Include package/commit, Racket version, OS/architecture, a minimal reproduction and the first redacted error. Never attach real keys, customer credentials, raw payment data or private documents. Community support has no guaranteed response time.

[Current licence](../LICENSE) · [CHANGELOG](../CHANGELOG.md)
