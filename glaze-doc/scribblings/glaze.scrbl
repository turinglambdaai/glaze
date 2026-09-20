#lang scribble/manual

@title{Glaze}
@author{turinglambdaai}

Glaze builds desktop applications with a Racket backend and a Web frontend
rendered inside a native OS window. Windows uses WebView2, macOS uses
WKWebView, and Linux uses WebKitGTK.

@section{Quick Start}

@verbatim{
 $ raco pkg install --auto glaze
 $ raco glaze init myapp
 $ cd myapp
 $ racket main.rkt
 # or: raco glaze dev
}

A Glaze application is @bold{native-GUI only}. If its native WebView cannot
start, application startup fails with platform-specific installation or repair
guidance. Glaze never substitutes a system-browser tab for the desktop window.

@section{Application Lifecycle}

@defmodule[glaze/app]

@defproc[(run-app
          [#:public-dir public-dir (or/c string? path?) "public"]
          [#:api api (listof route?) '()]
          [#:port port (or/c #f exact-nonnegative-integer?) #f]
          [#:title title string? "Glaze"]
          [#:width width exact-positive-integer? 1024]
          [#:height height exact-positive-integer? 768]
          [#:events events (or/c #f event-bus?) #f]
          [#:api-token api-token (or/c #f string? #t) #f]
          [#:on-close on-close (-> any) (lambda () (void))]
          [#:on-error on-error (or/c #f procedure?) #f]
          [#:check-update check-update (or/c #f string?) #f]
          [#:current-version current-version string? "0.0.0"]
          [#:on-ready on-ready procedure? (lambda (wv url) (void))])
         (values 'webview procedure?)]{
The one-call application entry point. It selects a free loopback port unless
@racket[#:port] is supplied, starts the static/API server, opens the native
WebView window, invokes @racket[on-ready] with the @racket[webview?] handle and
clean application URL, and blocks until the window closes.

When the native window closes, the local server is stopped and the procedure
returns @racket[(values 'webview shutdown)]. If native WebView startup fails,
Glaze first stops the local server and then propagates an actionable startup
error. There is intentionally no browser-fallback option.

@racket[#:api-token] may be a string or @racket[#t]. With @racket[#t], Glaze
generates a random capability token and uses a one-time bootstrap URL to set an
HttpOnly cookie for the embedded frontend. @racket[#:on-error] receives API
handler failures. @racket[#:check-update] wires an update manifest into the
application lifecycle.
}

@defproc[(make-api-token) string?]{
Returns a random 32-hex-character capability token.
}

@defparam[current-api-token token string?]{
Bound by @racket[run-app] so callbacks can read the active API token; the value
is the empty string when API-token protection is disabled.
}

@section{Local Server}

@defmodule[glaze/server]

@defproc[(start-server
          [#:port port exact-nonnegative-integer? 8080]
          [#:public-dir public-dir (or/c string? path?) "public"]
          [#:api api (listof route?) '()]
          [#:events events (or/c #f event-bus?) #f]
          [#:api-token api-token (or/c #f string?) #f]
          [#:serve-api-client? serve-api-client? boolean? #t])
         (values exact-nonnegative-integer? procedure?)]{
Starts the loopback HTTP server that powers the embedded frontend. Static
resources, SPA index fallback, JSON routes, generated API client, and optional
SSE event stream share the same origin. The return values are the actual port
and a shutdown procedure. @racket[start-dev-server] remains a compatibility
alias for this low-level server primitive; it does not define a browser-based
application mode.
}

@defproc[(stop-server [shutdown-proc procedure?]) void?]{Stops the server.}

@defmodule[glaze/browser]

@defproc[(open-browser [url string?]) void?]{
Explicitly opens an external URL in the user's default browser. This helper is
appropriate for documentation, OAuth, support pages, and similar external
resources. @racket[run-app], @racket[open-window], and @racket[open-webview]
do not use it as a fallback.
}

@section[#:tag "js-bridge"]{JavaScript Bridge}

@defmodule[glaze/api]

The embedded frontend calls Racket through ordinary same-origin HTTP requests.
This keeps the bridge easy to inspect and test with normal developer tools.

@defproc[(GET [path string?] [handler procedure?]) route?]{}
@defproc[(POST [path string?] [handler procedure?]) route?]{}
@defproc[(PUT [path string?] [handler procedure?]) route?]{}
@defproc[(DELETE [path string?] [handler procedure?]) route?]{}

A route handler receives the web-server request followed by any captured
@litchar{:param} path values. Returning a jsexpr produces a JSON 200 response;
a full response value may also be returned.

@defproc[(request-json-body [req request?]) jsexpr?]{
Parses a JSON request body. Missing, empty, or malformed input yields an empty
hash so route validation can produce a clean client error. JSON object keys in
Racket jsexprs are symbols, for example @racket[(hash-ref body 'delta)].
}

@defproc[(json-response [data jsexpr?]) response?]{}
@defproc[(api-response [data jsexpr?]) response?]{}
@defproc[(error-response [status exact-nonnegative-integer?]
                         [message string?]) response?]{}

@defmodule[glaze/api-macros]

@defform[(define-api-routes id clause ...)]{
Declares a callable Racket procedure, a validated HTTP route, and a generated
JavaScript client entry from one route clause.

@racketblock[
(define-api-routes api
  [(POST "api/counter/bump")
   (bump [delta exact-nonnegative-integer? 1])
   (hasheq 'count (add1 delta))])]

The generated @litchar{/glaze/api.js} exposes route-specific functions plus
@litchar{glaze.call(...)} and @litchar{glaze.on(...)}.
}

@section[#:tag "events"]{Event Push}

@defmodule[glaze/events]

Glaze uses same-origin Server-Sent Events for backend-to-frontend push.

@defproc[(make-event-bus) event-bus?]{Creates a broadcast event bus.}
@defproc[(bus-broadcast! [bus event-bus?]
                          [name (or/c symbol? string?)]
                          [data jsexpr?]) void?]{
Broadcasts an event without blocking the producer; a full per-subscriber
backlog drops that event for the slow subscriber only.
}
@defproc[(bus-subscribe! [bus event-bus?]) async-channel?]{}
@defproc[(bus-unsubscribe! [bus event-bus?] [channel async-channel?]) void?]{}
@defproc[(bus-wait [channel async-channel?] [seconds real? 10]) any/c]{}

@section{Native WebView}

@defmodule[glaze/webview/main]

The native WebView is an application prerequisite, not an optional rendering
mode. The backends are WebView2 on Windows, WKWebView on macOS, and WebKitGTK
on Linux.

@defproc[(open-window
          [url string?]
          [#:title title string? "Glaze"]
          [#:width width exact-positive-integer? 1024]
          [#:height height exact-positive-integer? 768]
          [#:devtools? devtools? boolean? #f]
          [#:on-close on-close (-> any) (lambda () (void))])
         webview?]{
Opens a native desktop window and loads @racket[url]. If the backend or its
runtime dependency is unavailable, this procedure raises. Before raising in
an interactive desktop process, Glaze also attempts to show an OS-level error
dialog so packaged GUI applications without a console still give the user an
actionable explanation. CI environments suppress the dialog and retain the
exception text in logs.

There is no @racket[#:fallback-browser?] keyword.
}

@defproc[(open-webview
          [url string?]
          [#:title title string? "Glaze"]
          [#:width width exact-positive-integer? 1024]
          [#:height height exact-positive-integer? 768]
          [#:devtools? devtools? boolean? #f]
          [#:on-close on-close (-> any) (lambda () (void))])
         webview?]{
Lower-level synonym of @racket[open-window] with the same fail-fast contract.
}

@defproc[(webview-supported?) boolean?]{
Non-throwing capability probe for the current platform backend. Actual window
creation remains the authoritative runtime check.
}

@defproc[(webview-last-error) any/c]{Returns the most recent backend probe/startup error.}
@defproc[(webview-install-guidance) string?]{
Returns platform-specific dependency guidance. Windows guidance names the
Microsoft Edge WebView2 Evergreen Runtime; Linux guidance names GTK 3 and
WebKitGTK packages; macOS explains that WKWebView is part of the OS.
}
@defproc[(webview-diagnostic) string?]{Formats the current error and guidance.}

@defproc[(webview-navigate [wv webview?] [url string?]) void?]{}
@defproc[(webview-close [wv webview?]) void?]{}
@defproc[(webview-title [wv webview?]) (or/c #f string?)]{}
@defproc[(webview-url [wv webview?]) (or/c #f string?)]{}
@defproc[(webview-capture! [wv webview?]
                            [dest (or/c #f string? path?) #f])
         (or/c #f path?)]{}
@defproc[(webview-set-title! [wv webview?] [title string?]) void?]{}
@defproc[(webview-set-size! [wv webview?]
                             [width exact-positive-integer?]
                             [height exact-positive-integer?]) void?]{}
@defproc[(webview-set-fullscreen! [wv webview?] [on? boolean?]) void?]{}
@defproc[(webview-focus! [wv webview?]) void?]{}
@defproc[(webview-set-menu! [wv webview?] [menus list?]) void?]{}
@defproc[(webview-closed? [wv webview?]) boolean?]{}
@defproc[(all-webviews) (listof webview?)]{}
@defproc[(close-all-webviews!) void?]{}
@defproc[(wait-for-webviews [timeout-seconds (or/c #f real?) #f]) boolean?]{}

@subsection{Startup Dependency Feedback}

When native startup fails, Glaze reports the backend error and remediation.
Typical guidance includes:

@itemlist[
 @item{Windows: install or repair Microsoft Edge WebView2 Runtime (Evergreen),
       with a @exec{winget} command and Microsoft's official download page.}
 @item{Debian/Ubuntu: @exec{sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0}.}
 @item{Fedora: @exec{sudo dnf install gtk3 webkit2gtk4.1}.}
 @item{Arch: @exec{sudo pacman -S gtk3 webkit2gtk-4.1}.}
 @item{macOS: WKWebView is built in; use a logged-in graphical session and
       report the preserved backend error if initialization still fails.}]

Set environment variable @envvar{GLAZE_NO_STARTUP_DIALOG} to @litchar{1} to
suppress the interactive error dialog while retaining the exception. Dialogs
are also suppressed automatically under common CI environments.

@section{System Integrations}

@defmodule[glaze/sys]

@defproc[(sys-supported?) boolean?]{}
@defproc[(clipboard-set! [text string?]) boolean?]{}
@defproc[(clipboard-get) string?]{}
@defproc[(notify! [title string?]
                   [body string? ""]
                   [#:subtitle subtitle string? ""]) boolean?]{}
@defproc[(open-path [path-or-url (or/c path? string?)]) boolean?]{}
@defproc[(reveal-path [path (or/c path? string?)]) boolean?]{}
@defproc[(single-instance? [app-id any/c]) boolean?]{}

These helpers are best-effort integrations. Their failure semantics are
separate from the WebView startup contract: the WebView is required for the
application itself, while an optional integration may report failure without
changing the application's rendering model.

@section{System Tray}

@defmodule[glaze/tray]

@defproc[(tray-supported?) boolean?]{}
@defproc[(make-tray [#:icon icon any/c]
                    [#:tooltip tooltip string?]
                    [#:menu menu list?]
                    [#:on-event on-event procedure? (lambda (e) (void))])
         tray?]{}
@defproc[(tray-set-tooltip! [tray tray?] [tooltip string?]) void?]{}
@defproc[(tray-set-icon! [tray tray?] [icon any/c]) void?]{}
@defproc[(tray-set-menu! [tray tray?] [menu list?]) void?]{}
@defproc[(tray-close [tray tray?]) void?]{}

The tray remains an optional capability. If its native backend is unavailable,
Glaze may use an inert tray stub; this does not weaken the mandatory native
WebView contract for the main window.

@section[#:tag "security"]{Security}

The local server binds to loopback and validates Host headers against
@litchar{127.0.0.1}, @litchar{localhost}, and @litchar{[::1]} to reduce DNS
rebinding risk.

With @racket[#:api-token], API routes and the SSE stream require a capability.
@racket[run-app] opens the native WebView at a one-time bootstrap URL; the
server exchanges the token for an HttpOnly cookie and redirects to the clean
path. Programmatic clients may use the @litchar{X-Glaze-Token} header.

This is defense in depth against casual local callers, not isolation from
other processes running as the same OS user.

@section[#:tag "update-checks"]{Update Checks}

@defmodule[glaze/update]

@defproc[(check-update [manifest-url string?]
                        [#:current-version current-version string? "0.0.0"])
         (or/c #f hash?)]{
Checks a JSON manifest for a newer version. An optional @litchar{sha256} field
is passed through for artifact verification.
}
@defproc[(newer-version? [candidate string?] [current string?]) boolean?]{}
@defproc[(verify-file-sha256 [path (or/c string? path?)]
                             [expected-hex string?]) boolean?]{
Returns @racket[#t] only for a verified digest; @racket[#f] also covers cases
where verification could not be performed.
}

@section{Licensing}

@defmodule[glaze/license]

Glaze includes an offline RSA-2048/SHA-256 licensing helper backed by the
system @exec{openssl} command.

@defproc[(issue-license [#:private-key private-key path-string?]
                        [#:product product string?]
                        [#:subject subject string?]
                        [#:expiry expiry (or/c #f string?) #f]
                        [#:machine-id machine-id (or/c #f string?) #f]
                        [#:out output (or/c string? path?) "app.license"])
         path?]{}
@defproc[(validate-license [license-file (or/c string? path?)]
                           [#:public-key public-key path-string?]
                           [#:product product string?]
                           [#:machine-id machine-id string? (machine-id)])
         hash?]{}
@defproc[(license-valid? [license-file (or/c string? path?)]
                         [#:public-key public-key path-string?]
                         [#:product product string?]
                         [#:machine-id machine-id string? (machine-id)])
         boolean?]{}
@defproc[(machine-id) string?]{}
@defproc[(days-until-expiry [expiry string?]) exact-integer?]{}

@section{File Dialogs}

@defmodule[glaze/dialogs]

@defproc[(dialog-supported?) boolean?]{}
@defproc[(pick-file [#:title title (or/c #f string?) #f]
                    [#:directory directory (or/c #f path-string?) #f]
                    [#:filters filters list? '()])
         (or/c #f path?)]{}
@defproc[(pick-files [#:title title (or/c #f string?) #f]
                     [#:directory directory (or/c #f path-string?) #f]
                     [#:filters filters list? '()])
         (listof path?)]{}
@defproc[(pick-folder [#:title title (or/c #f string?) #f]
                      [#:directory directory (or/c #f path-string?) #f])
         (or/c #f path?)]{}
@defproc[(save-file-dialog [#:title title (or/c #f string?) #f]
                           [#:default-name default-name (or/c #f string?) #f]
                           [#:directory directory (or/c #f path-string?) #f]
                           [#:filters filters list? '()])
         (or/c #f path?)]{}

@section{Deep Links and Launch at Login}

@defmodule[glaze/deeplink]

@defproc[(ensure-url-scheme! [scheme string?]
                             [#:app-name app-name string? scheme])
         any/c]{
Windows registers a user-scope URL protocol, Linux writes a desktop entry and
uses @exec{xdg-mime} when available, and macOS URL schemes are declared in the
bundle at build time.
}

@defmodule[glaze/autolaunch]

@defproc[(auto-launch-set! [name string?] [enabled? boolean?]) void?]{}
@defproc[(auto-launch-enabled? [name string?]) any/c]{}

@section{Packaging}

@defmodule[glaze/build]

@defproc[(build-app
          [#:entry entry (or/c string? path?) "main.rkt"]
          [#:name name (or/c #f string?) #f]
          [#:version version (or/c #f string?) #f]
          [#:icon icon any/c #f]
          [#:out-dir out-dir (or/c string? path?) "dist"]
          [#:embed-dlls? embed-dlls? boolean? #f]
          [#:installer? installer? boolean? #f]
          [#:sign sign (or/c #f string?) #f]
          [#:entitlements entitlements any/c #f]
          [#:no-hardened-runtime? no-hardened-runtime? boolean? #f]
          [#:timestamp-url timestamp-url (or/c #f string?) #f]
          [#:notarize-profile notarize-profile (or/c #f string?) #f]
          [#:url-schemes url-schemes list? '()])
         path?]{
Builds and distributes the application with @exec{raco exe} and
@exec{raco distribute}. Windows GUI builds use @exec{raco exe --gui}, so they
may not have a visible console; this is why native WebView startup failures
also attempt an OS-level error dialog.

Installer-toolchain absence may degrade an installer request to an archive
with a loud warning. That packaging fallback is unrelated to runtime startup:
the built application still requires its native WebView.
}

@section{CLI Commands}

@verbatim{
 raco glaze init <name>                Create a native desktop project
 raco glaze dev                        Run the project's native main.rkt
 raco glaze build                      Build a distributable / installer
 raco glaze keygen [--out <dir>]       Create an RSA keypair for licenses
 raco glaze license sign|verify        Sign or verify license files
 raco glaze help                       Show help
}

There is intentionally no browser-mode @exec{dev} or @exec{serve} command.
Development and production use the same native WebView startup path.
