# GUI-first startup policy

Glaze is a desktop GUI framework. Application entry points (`run-app`, `open-window`, and `open-webview`) require a working native WebView backend and never fall back to the system browser.

If native startup fails, Glaze preserves the underlying backend error and adds platform-specific remediation:

- **Windows:** install or repair Microsoft Edge WebView2 Runtime (Evergreen). The diagnostic includes `winget install --id Microsoft.EdgeWebView2Runtime -e` and Microsoft's official WebView2 download page. Glaze itself ships `WebView2Loader.dll`.
- **macOS:** WKWebView is part of macOS; run from a logged-in graphical session and report the preserved backend error if initialization still fails.
- **Linux:** install GTK 3 + WebKitGTK for the distribution and run inside a graphical desktop session (or Xvfb in CI).

A packaged GUI application may not have a visible console, especially on Windows where Glaze builds with `raco exe --gui`. For that reason, an interactive startup failure also attempts to show an OS-level error dialog containing the same diagnosis before the exception terminates the application. CI/GitHub Actions suppress the dialog so unattended jobs cannot block. Set `GLAZE_NO_STARTUP_DIALOG=1` to suppress it explicitly.

This policy is intentional: a desktop application that unexpectedly becomes a browser tab is a different application model and hides dependency/backend failures during development. Optional helpers such as `open-browser` remain available for deliberately opening external documentation, OAuth pages, and similar URLs, but they are not part of native application startup.
