#lang scribble/manual

@title{Glaze}
@author{turinglambdaai}

Build desktop apps with Racket backend and web frontend.

@section{Quick Start}

@verbatim{
 $ raco pkg install --auto glaze
 $ raco glaze init myapp
 $ cd myapp
 $ racket main.rkt
}

@section{Core API}

@defmodule[glaze/app]

@defproc[(run-app
          [#:public-dir public-dir (or/c string? path?) "public"]
          [#:api api (listof route?) '()]
          [#:port port (or/c #f exact-nonnegative-integer?) #f]
          [#:title title string? "Glaze"]
          [#:width width exact-positive-integer? 1024]
          [#:height height exact-positive-integer? 768]
          [#:fallback-browser? fallback-browser? boolean? #t]
          [#:events events (or/c #f event-bus?) #f]
          [#:api-token api-token (or/c #f string? #t) #f]
          [#:on-close on-close (-> any) (lambda () (void))]
          [#:on-error on-error (or/c #f (exn? string? . -> . any)) #f]
          [#:check-update check-update (or/c #f string?) #f]
          [#:current-version current-version string? "0.0.0"]
          [#:on-ready on-ready (-> (or/c webview? #f) string? any)
                      (lambda (wv url) (void))])
         (values (or/c 'webview 'browser) procedure?)]{
The one-call entry: picks a free port (unless @racket[#:port] is given),
starts the server (static + JSON API, optional SSE event bus and API token),
opens the native webview window, and blocks until the window closes.
@racket[on-ready] receives the webview handle and URL as soon as the window
is up — the hook agents use for verification. @racket[on-error], when given,
receives every API-handler failure (the 500 path) for crash reporting.
When @racket[#:api-token] is @racket[#t], a random token is generated
(@racket[make-api-token]) and printed in the browser fallback path.
When @racket[#:check-update] is a manifest URL, a background check runs
(see @secref["update-checks"]).

Returns @racket['webview] after a window-driven shutdown (server already
stopped) or @racket['browser] immediately after opening the system-browser
fallback (server still running; call the returned shutdown procedure to stop
it).
}

@defproc[(make-api-token) string?]{ A random 32-hex-character capability
token (CSPRNG) for use with @racket[#:api-token]. }

@defparam[current-api-token token string?]{
Bound by @racket[run-app] so callbacks can read the active token (empty when
the API is open).
}

@defmodule[glaze/server]

@defproc[(start-server
          [#:port port exact-nonnegative-integer? 8080]
          [#:public-dir public-dir (or/c string? path?) "public"]
          [#:api api (listof route?) '()]
          [#:events events (or/c #f event-bus?) #f]
          [#:api-token api-token (or/c #f string?) #f]
          [#:serve-api-client? serve-api-client? boolean? #t])
         (values exact-nonnegative-integer? procedure?)]{
Starts a local HTTP server on @racket[127.0.0.1] serving static files from
@racket[public-dir] (SPA index.html fallback) with optional JSON API routes
(see @secref["js-bridge"]). Verifies the listener is accepting before
returning. Returns the port and a shutdown procedure.

@racket[#:events] mounts the SSE endpoint @litchar{GET /glaze/events}
(see @secref["events"]). @racket[#:api-token] guards the API routes and the
SSE stream (see @secref["security"]). @racket[#:serve-api-client?] controls
the generated JS client at @litchar{GET /glaze/api.js}.
@racket[start-dev-server] is a backward-compatible alias.
}

@defproc[(stop-server [shutdown-proc procedure?]) void?]{
Stops the server.
}

@defparam[current-glaze-error-reporter reporter
          (exn? string? . -> . any)]{
Receives API-handler failures (the 500 path). Defaults to logging on stderr;
@racket[run-app] parameterizes this to its @racket[#:on-error] callback.
}

@defmodule[glaze/browser]

@defproc[(open-browser [url string?]) void?]{
Opens the system browser to the given URL.
}

@section[#:tag "js-bridge"]{JavaScript Bridge}

@defmodule[glaze/api]

The page calls Racket with plain @litchar{fetch("/api/...")}; Racket answers
JSON. One code path works in the embedded WebView, in the system-browser
fallback, and in dev (curl-able).

@defproc[(GET [path string?] [handler procedure?]) route?]{}
@defproc[(POST [path string?] [handler procedure?]) route?]{}
@defproc[(PUT [path string?] [handler procedure?]) route?]{}
@defproc[(DELETE [path string?] [handler procedure?]) route?]{
Build a route for @racket[path]. @litchar{":x"} segments capture the
request path segment as a string. The handler receives the web-server
request followed by the captured values and returns a jsexpr (auto-wrapped
as a 200 JSON response) or a full response.
}

@defproc[(request-json-body [req request?]) jsexpr?]{
Parses the request body as JSON; a missing, empty, or invalid body yields
the empty hash so optional parameters fall back to defaults and required
ones report a clean 400. Racket jsexpr parses JSON object keys as
@bold{symbols}: @racket[(hash-ref body 'delta)].
}

@defproc[(json-response [data jsexpr?]) response?]{ A 200 JSON response. }
@defproc[(api-response [data jsexpr?]) response?]{ Same as @racket[json-response]. }
@defproc[(error-response [status exact-nonnegative-integer?] [msg string?])
         response?]{ A JSON error response with the given status code. }

@defproc[(exn:fail:glaze:bad-param? [v any/c]) boolean?]{
Raised by @racket[define-api-routes] argument checking; the server maps it
to a 400 naming the parameter. A plain @racket[exn:fail] from a handler
stays a 500.
}

@codeblock|{
#lang racket/base
(require glaze)
(run-app
 #:public-dir "public"
 #:api (list
        (POST "api/counter/bump"
              (lambda (req)
                (define body (request-json-body req))
                (bump! (hash-ref body 'delta 1))))))
}|

@subsection[#:tag "typed-routes"]{Typed Routes: @racket[define-api-routes]}

@defmodule[glaze/api-macros]

@defform[(define-api-routes id clause ...)]{
Each @racket[clause] has the shape

@racketblock[
[(METHOD _path)
 (_proc _param ...)
 _body ...+]]

and defines @bold{three} things from one declaration:

@itemlist[
 @item{a Racket procedure @racket[_proc], callable directly (tests
       included);}
 @item{a route added to @racket[id] — JSON body keys and @litchar{":x"} path
       captures become the procedure's arguments;}
 @item{a JS client entry served at @litchar{/glaze/api.js} (see below).}]

Parameter forms: plain @racket[_id] (required, any value),
@racket[[_id predicate]] (required, checked), or
@racket[[_id predicate default]] (optional with default). Bad input raises
a 400 naming the parameter; handler exceptions stay 500.

@codeblock|{
#lang racket/base
(require glaze)
(define-api-routes api
  [(POST "api/counter/bump")
   (bump [delta exact-nonnegative-integer? 1])
   (begin (bump! delta) (hasheq 'count (count)))]
  [(GET "api/items/:id")
   (item id)
   (hasheq 'id id)])
(run-app #:public-dir "public" #:api api)
}|
}

@subsection[#:tag "js-client"]{The Generated JS Client}

With routes registered, @litchar{GET /glaze/api.js} serves a client derived
from them: each route becomes a @litchar{glaze.api.*} function (path
params become arguments), plus the generic
@litchar{glaze.call(method, path, body)} and
@litchar{glaze.on(name, fn)} (an EventSource wrapper over
@litchar{/glaze/events}). Disable with
@racket[#:serve-api-client? #f].

@verbatim|{
const s = await glaze.api.counterBump({delta: 5});
glaze.on('count-changed', s => render(s.count));
}|

@section[#:tag "events"]{Event Push (SSE)}

@defmodule[glaze/events]

Backend-to-frontend push — Glaze's answer to Tauri's @litchar{emit()} and
Eel's websocket push — over plain Server-Sent Events on the same origin, so
the browser fallback gets push for free.

@defproc[(make-event-bus) event-bus?]{ A broadcast bus. Pass it to
@racket[start-server]/@racket[run-app] via @racket[#:events] to mount
@litchar{GET /glaze/events} (15s keepalive; per-subscriber bounded backlog
with drop-on-overflow; disconnect cleanup). }

@defproc[(bus-broadcast! [bus event-bus?] [name (or/c symbol? string?)]
                          [data jsexpr?]) void?]{
Deliver @racket[(list name data)] to every subscriber, from any thread.
Non-blocking: a full backlog drops the event for that subscriber only.
}

@defproc[(bus-subscribe! [bus event-bus?]) async-channel?]{
Register a new subscriber; returns an asynchronous channel of
@racket[(list name data)] pairs (for non-SSE consumers).
}

@defproc[(bus-unsubscribe! [bus event-bus?] [ch async-channel?]) void?]{}

@defproc[(bus-wait [ch async-channel?] [secs real? 10])
         (or/c (list/c symbol? jsexpr?) 'timeout)]{
Blocking receive with timeout — for tests and non-SSE consumers.
}

In the page:

@verbatim|{
const es = new EventSource('/glaze/events');
es.addEventListener('count-changed', e => render(JSON.parse(e.data).count));
}|

@section{System Integrations}

@defmodule[glaze/sys]

Desktop-system integrations beyond the tray, with the same platform
dispatch (and no-op degradation) as @racket[glaze/tray]. All procedures are
best-effort and never raise for environmental reasons.

@defproc[(sys-supported?) boolean?]{ Whether the current platform backend
loaded its native libraries. }

@defproc[(clipboard-set! [text string?]) boolean?]{ Places text on the
system clipboard. }

@defproc[(clipboard-get) string?]{ Reads text from the system clipboard
(@litchar{""} when empty or unavailable). }

@defproc[(notify! [title string?] [body string? ""]
                   [#:subtitle subtitle string? ""]) boolean?]{
Shows a desktop notification; delivery itself is best-effort (OS settings
may suppress it).
}

@defproc[(open-path [p (or/c path? string?)]) boolean?]{
Opens a path or URL with the OS default handler.
}

@defproc[(reveal-path [p (or/c path? string?)]) boolean?]{
Reveals a file in Finder / Explorer / the file manager, selecting it.
}

@defproc[(single-instance? [app-id any/c]) boolean?]{
Adjudicates @litchar{"am I the first instance?"} without leaving files
behind: derives a deterministic TCP port from the id and holds a listener on
it for the process lifetime. The second instance's bind fails and gets
@racket[#f]. (A firewall prompt is possible on first run on some systems.)
}

Window controls live in @racket[glaze/webview]: @racket[webview-set-title!],
@racket[webview-set-size!], @racket[webview-set-fullscreen!],
@racket[webview-focus!].

@section[#:tag "update-checks"]{Update Checks}

@defmodule[glaze/update]

Glaze deliberately stops at @emph{notification} — downloading and replacing
a running app is a per-distribution decision (notarized DMG, MSI upgrade,
AppImage overwrite); the app decides what an @litchar{update-available}
event means.

@defproc[(check-update [manifest-url string?]
                        [#:current-version current string? "0.0.0"])
         (or/c #f hash?)]{
Fetches a JSON manifest @litchar|{{"version","url","notes"}}| (5s timeout;
HTTPS needs the @racket[openssl] collection) and compares versions
numerically (@litchar{"1.10"} > @litchar{"1.9"}). Returns
@racket[(hasheq 'version _ 'url _ 'notes _ 'sha256 _)] when a newer version
exists, @racket[#f] otherwise. The manifest may carry an optional
@litchar{"sha256"} field (hex digest of the artifact at @racket[_url]);
it is passed through untouched.
}

@defproc[(newer-version? [candidate string?] [current string?]) boolean?]{}

@defproc[(verify-file-sha256 [path (or/c string? path?)] [expected-hex string?]) boolean?]{
True when the file at @racket[path] has the given SHA-256 digest
(case-insensitive). @racket[#f] means @emph{cannot verify} (missing
openssl, unreadable file) — never treat @racket[#f] as verified. Use it
after downloading an update artifact, before swapping it in.
}

@racket[run-app]'s @racket[#:check-update] and @racket[#:current-version]
wire this up: the result is printed to stderr and broadcast as
@litchar{update-available} on the event bus (when @racket[#:events] is
given).

@section[#:tag "licensing"]{Licensing (Paid Apps)}

@defmodule[glaze/license]

An offline license-key scheme with zero native dependencies: RSA-2048 /
SHA-256 signatures computed by the system @racket[openssl] CLI (present on
macOS and Linux out of the box; Git for Windows ships it too). A license
file is JSON claims (@racket[product], @racket[subject], optional
@racket[expiry] and @racket[machine-id]) plus a base64 @racket[signature].

Vendor workflow:

@verbatim{
 $ raco glaze keygen --out keys          ; once: private.pem + public.pem
 $ raco glaze license sign --key keys/private.pem --product "MyApp" \\
     --subject "Acme Corp" --expiry 2027-12-31 --out app.license
 $ raco glaze license verify --pub keys/public.pem --product "MyApp" app.license
}

@defproc[(issue-license [#:private-key private-key path-string?]
                        [#:product product string?]
                        [#:subject subject string?]
                        [#:expiry expiry (or/c #f string?) #f]
                        [#:machine-id machine (or/c #f string?) #f]
                        [#:out out (or/c string? path?) "app.license"])
         path?]{
Signs and writes a license file; returns its path.
}

@defproc[(validate-license [license-file (or/c string? path?)]
                           [#:public-key public-key path-string?]
                           [#:product product string?]
                           [#:machine-id machine string? (machine-id)])
         hash?]{
Returns @racket[(hasheq 'valid #t 'subject _ 'expiry _ 'machine-id _)] on
success, or @racket[(hasheq 'valid #f 'reason _)] with a stable reason tag:
@racket["missing-file"], @racket["malformed"], @racket["signature"],
@racket["product"], @racket["expired"], @racket["machine"],
@racket["openssl-unavailable"].
}

@defproc[(license-valid? [license-file (or/c string? path?)]
                         [#:public-key public-key path-string?]
                         [#:product product string?]
                         [#:machine-id machine string? (machine-id)])
         boolean?]{}

@defproc[(machine-id) string?]{
A stable per-machine digest (64 lowercase hex chars) of the OS machine
identifier — IOPlatformUUID (macOS), @filepath{/etc/machine-id} (Linux),
MachineGuid (Windows) — with a username+hostname fallback. The raw OS
identifier never leaves the function. Honest scope: machine binding is a
courtesy check against casual license sharing, not tamper resistance.
}

@defproc[(days-until-expiry [expiry string?]) exact-integer?]{
Days until an @litchar{"YYYY-MM-DD"} date (expiry day inclusive); negative
when past. Raises on a malformed date.
}

@section[#:tag "dialogs"]{File Dialogs}

@defmodule[glaze/dialogs]

Native open/save dialogs: @racket[NSOpenPanel]/@racket[NSSavePanel]
(macOS), @racket[GetOpenFileNameW]/@racket[GetSaveFileNameW] (Windows),
@exec{zenity}/@exec{kdialog} (Linux). Dialogs block the calling thread.

@defproc[(pick-file [#:title title (or/c #f string?) #f]
                    [#:directory directory (or/c #f path-string?) #f]
                    [#:filters filters list? '()])
         (or/c #f path?)]{
Opens one file. @racket[filters] is a list of
@racket[(list "Human name" "*.txt" "*.md")]. @racket[#f] = cancelled.
}

@defproc[(pick-files [#:title title (or/c #f string?) #f]
                     [#:directory directory (or/c #f path-string?) #f]
                     [#:filters filters list? '()])
         (listof path?)]{
Multi-select; empty list = cancelled.
}

@defproc[(pick-folder [#:title title (or/c #f string?) #f]
                      [#:directory directory (or/c #f path-string?) #f])
         (or/c #f path?)]{}

@defproc[(save-file-dialog [#:title title (or/c #f string?) #f]
                           [#:default-name default-name (or/c #f string?) #f]
                           [#:directory directory (or/c #f path-string?) #f]
                           [#:filters filters list? '()])
         (or/c #f path?)]{
The overwrite prompt is the dialog's; no file is created here.
}

@defproc[(dialog-supported?) boolean?]{@racket[#f] when no dialog backend
exists on this platform (open/save then raise).}

@section[#:tag "menus"]{Menu Bar}

@defmodule[glaze/webview]

@defproc[(webview-set-menu! [wv webview?] [menus (listof menu?)]) void?]{
Replaces the custom section of the application menu bar. Menus are
declared with the tray protocol vocabulary:
@racket[(list (make-menu "File" (list (make-menu-item "Open…" #:accel
"CmdOrCtrl+O" #:action open-doc) menu-separator)))]. Accelerator
keystrokes fire for real on macOS; on Windows/Linux they are displayed
next to the label (v1). The platform-standard menus (Edit/Window on macOS)
are preserved.
}

@defproc[(webview-closed? [wv webview?]) boolean?]{True once the window is
closed — by @racket[webview-close] or the OS chrome.}

@defproc[(all-webviews) (listof webview?)]{Every window this process
opened that is not yet garbage collected.}

@defproc[(close-all-webviews!) void?]{Closes every open window (each
delivers its @racket[#:on-close]).}

@defproc[(wait-for-webviews [timeout-secs (or/c #f real?) #f]) boolean?]{
Blocks until every open window closes; @racket[#f] on timeout.
}

@section[#:tag "deeplink-autolaunch"]{Deep Links & Launch at Login}

@defmodule[glaze/deeplink]

@defproc[(ensure-url-scheme! [scheme string?]
                             [#:app-name app-name string? scheme])
         symbol?]{
Registers @racket[scheme]:// for this executable, idempotently. Windows:
HKCU registry entries. Linux: a desktop entry plus @exec{xdg-mime default}.
macOS: handlers are declared in the packaged Info.plist — pass
@racket[#:url-schemes] to @racket[build-app] (or
@exec{raco glaze build --url-scheme}); the runtime call returns
@racket['build-time]. Receiving the URL is the established
single-instance + argv pattern: the OS launches the executable with the
URL as an argument.
}

@defmodule[glaze/autolaunch]

@defproc[(auto-launch-set! [name string?] [enabled? boolean?]) void?]{}

@defproc[(auto-launch-enabled? [name string?])
         (or/c boolean? 'requires-approval 'not-registered)]{
macOS uses SMAppService (macOS 13+, packaged .app, no permission prompt);
Windows the HKCU Run key; Linux autostart desktop entries.
}

@section[#:tag "signing"]{Code Signing & Notarization}

Unsigned apps are blocked by macOS Gatekeeper and Windows SmartScreen.
@racket[build-app] and @racket[raco glaze build] drive the platform
signer:

@itemlist[
 @item{macOS: @exec{codesign} with an identity (@litchar{"-"} = ad-hoc);
   nested code (the bundled Racket framework) is signed first, then the
   bundle. @racket[#:notarize-profile] submits the built dmg via
   @exec{xcrun notarytool}, waits, and staples the ticket.}
 @item{Windows: @exec{signtool} with a SHA-1 thumbprint or subject name,
   RFC-3161 timestamped by default so signatures outlive the certificate.}
]

Signing @emph{failures} abort the build; a @emph{missing toolchain}
degrades with a loud warning. On macOS, hardened runtime
(@racket[#:no-hardened-runtime?] disables it) is applied unless the
identity is ad-hoc — its library validation would reject the app's own
ad-hoc-signed framework.

@section{System Tray}

@defmodule[glaze/tray]

Glaze provides a cross-platform system tray backed by pure Racket FFI
(Windows @racket[Shell_NotifyIconW], macOS @racket[NSStatusItem], Linux
@racket[libayatana-appindicator]). When a platform's native libraries are
unavailable, the tray degrades to a no-op stub.

@defproc[(make-tray
          [#:icon icon (or/c #f path?)]
          [#:tooltip tooltip string?]
          [#:menu items (listof menu-item?)])
         tray?]{
Creates a system tray icon with the given tooltip and menu. Returns a tray
handle. Never raises for environmental reasons — callers always get a usable
(possibly inert) handle.
}

@defproc[(tray-set-tooltip! [t tray?] [tooltip string?]) void?]{}
@defproc[(tray-set-icon! [t tray?] [icon path?]) void?]{}
@defproc[(tray-set-menu! [t tray?] [items (listof menu-item?)]) void?]{}
@defproc[(tray-close [t tray?]) void?]{}

@defproc[(make-menu-item
          [label string?]
          [#:id id any/c label]
          [#:action action (-> any) void]
          [#:enabled? enabled? boolean? #t]
          [#:checked? checked? boolean? #f])
         menu-item?]{}
@defproc[(menu-separator) menu-item?]{}

@section{Native WebView}

@defmodule[glaze/webview/main]

Opens a native OS window with an embedded WebView pointing at a URL
(typically the local HTTP server Glaze started). Backends: macOS
(@racket[NSWindow] + @racket[WKWebView] via objc FFI), Windows (WebView2
via COM FFI), Linux (@racket[GtkWindow] + WebKitGTK via FFI) — all three
pass the real-window CI e2e (open, load, capture, navigate, close,
on-close). When the native backend is unavailable, @racket[open-window]
returns @racket[#f] so callers can fall back to @racket[open-browser].

@defproc[(open-window
          [url string?]
          [#:title title string? "Glaze"]
          [#:width width exact-positive-integer? 1024]
          [#:height height exact-positive-integer? 768]
          [#:devtools? devtools? boolean? #f]
          [#:on-close on-close (-> any) (lambda () (void))]
          [#:fallback-browser? fallback-browser? boolean? #f])
         (or/c webview? #f)]{
Opens the window and loads @racket[url]. @racket[on-close] runs when the
window closes (programmatic @racket[webview-close] or the user closing it).
@racket[#:devtools?] opens the platform inspector (macOS: inspectable,
13+; Windows: @litchar{OpenDevToolsWindow}; Linux: WebKitGTK inspector).
Returns @racket[#f] when the backend is unavailable; with
@racket[#:fallback-browser?] the system browser is opened instead.
@racket[open-webview] is a synonym.
}

@defproc[(webview-supported?) boolean?]{
Whether the current platform backend is available.
}

@defproc[(webview-navigate [wv webview?] [url string?]) void?]{
Loads a new URL into an open webview.
}

@defproc[(webview-close [wv webview?]) void?]{
Closes the window and stops its event pump.
}

@defproc[(webview-title [wv webview?]) (or/c #f string?)]{
Current page title once the first navigation has committed; @racket[#f]
before that or when the backend cannot provide it.
}

@defproc[(webview-url [wv webview?]) (or/c #f string?)]{
Current page URL once the first navigation has committed.
}

@defproc[(webview-capture!
          [wv webview?]
          [dest (or/c #f string? path?) #f])
         (or/c #f path?)]{
Captures the window contents as a PNG to @racket[dest] (a fresh temp file by
default). Returns the path, or @racket[#f] when the window is closed or not
currently capturable. Together with @racket[webview-title] and
@racket[webview-url], this lets automated callers — including AI agents —
verify what the UI is showing without a human at the screen.
}

@defproc[(webview-set-title! [wv webview?] [title string?]) void?]{}
@defproc[(webview-set-size! [wv webview?]
                             [width exact-positive-integer?]
                             [height exact-positive-integer?]) void?]{}
@defproc[(webview-set-fullscreen! [wv webview?] [on? boolean?]) void?]{}
@defproc[(webview-focus! [wv webview?]) void?]{}

@section[#:tag "security"]{Security}

The server binds to @racket[127.0.0.1] only, and every request passes a
Host-header check: the server must be addressed as @litchar{127.0.0.1} /
@litchar{localhost} / @litchar{[::1]} (with or without port). This closes
the DNS-rebinding hole where a malicious page resolves its own domain to
loopback to reach the app's API; hostile origins get 403.

The optional API token (@racket[#:api-token]) guards @emph{capabilities} —
API routes and the SSE stream (401 otherwise) — not resources: static files
and the api.js bootstrap stay open. @racket[run-app] opens the window at a
one-time capability URL, @litchar{/?glaze-token=...}: the server exchanges
the token for an @litchar{HttpOnly} @litchar{glaze_token} cookie and
redirects to the clean path (EventSource cannot set headers, but
same-origin requests carry cookies). api.js deliberately hands out nothing,
so a caller that can only read openly-served endpoints cannot mint
credentials. Programmatic clients send @litchar{X-Glaze-Token}.

@bold{Honest scope:} this raises the bar against casual local callers; a
process running as the same user can still read the token from process
memory — full local-process isolation is not achievable over plain HTTP.

@section{Packaging}

@defmodule[glaze/build]

@defproc[(build-app
          [#:entry entry (or/c string? path?) "main.rkt"]
          [#:name name (or/c #f string?) #f]
          [#:version version (or/c #f string?) #f]
          [#:icon icon (or/c #f path?) #f]
          [#:out-dir out-dir (or/c string? path?) "dist"]
          [#:embed-dlls? embed-dlls? boolean? #f]
          [#:installer? installer? boolean? #f]
          [#:sign sign (or/c #f string?) #f]
          [#:entitlements entitlements (or/c #f path?) #f]
          [#:no-hardened-runtime? no-hardened-runtime? boolean? #f]
          [#:timestamp-url timestamp-url (or/c #f string?) #f]
          [#:notarize-profile notarize-profile (or/c #f string?) #f])
         path?]{
Builds a Glaze project into a distributable via @racket[raco exe] +
@racket[raco distribute], bundling the project's @racket[public/] with the
executable. On macOS assembles a canonical @tt{.app} bundle (with
@racket[version] stamped into @tt{Info.plist}) and, when
@racket[installer?] is true, produces a dmg (msi on Windows, AppImage on
Linux), falling back to a zip / tar.gz when the native toolchain is
absent. @racket[sign] is a codesign identity on macOS (@litchar{"-"} =
ad-hoc) or a signtool certificate SHA-1 thumbprint / subject on Windows;
@racket[notarize-profile] adds notarization + stapling. See
@secref["signing"]. Signing failures abort the build; a missing toolchain
degrades with a warning.
}

@section{CLI Commands}

@verbatim{
 raco glaze init <name>                Create a new project
 raco glaze dev                        Start dev server
 raco glaze build                      Build a distributable (+ optional
                                       installer, signing, notarization)
 raco glaze keygen [--out <dir>]       Create an RSA keypair for licenses
 raco glaze license sign|verify        Sign or verify license files
}
