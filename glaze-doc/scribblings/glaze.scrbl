#lang scribble/manual

@title{Glaze}
@author{turinglambdaai}

Glaze builds desktop applications with a Racket backend and a Web frontend
rendered inside a native OS window. Windows uses WebView2, macOS uses
WKWebView, and Linux uses WebKitGTK.

@bold{Human-first. Agent-native. Local by design.} New projects include an
agent instruction contract and native-window verification script. The CLI
exposes machine-readable project inspection and runtime diagnostics without
changing Glaze's human-readable workflow.

@section{Quick Start}

@verbatim{
 $ raco pkg install --auto glaze
 $ raco glaze init myapp
 $ cd myapp
 $ raco glaze inspect --json
 $ raco glaze doctor --json
 $ raco glaze verify
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
          [#:capability capability (or/c #f capability?) #f]
          [#:on-close on-close (-> any) (lambda () (void))]
          [#:on-error on-error (or/c #f procedure?) #f]
          [#:check-update check-update (or/c #f string?) #f]
          [#:current-version current-version string? "0.0.0"]
          [#:app-id app-id (or/c #f string?) #f]
          [#:window-state window-state (or/c #f #t path-string?) #f]
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

When @racket[#:capability] is supplied, @racket[run-app] automatically creates
an API token if necessary. Every API route then requires a declared and granted
permission; this mode is default-deny.

With @racket[#:window-state #t], @racket[#:app-id] selects a platform config
path where Glaze saves outer position, size, and maximized state at close and
restores them on the next launch. An explicit path may be supplied instead.
Stale geometry is clamped to the current virtual desktop so a disconnected
monitor cannot strand the window.
}

@defproc[(make-api-token) string?]{
Returns a random 32-hex-character capability token.
}

@defparam[current-api-token token string?]{
Bound by @racket[run-app] so callbacks can read the active API token; the value
is the empty string when API-token protection is disabled.
}

@section{Local Server}

@defmodule*[(glaze/server glaze/browser)]

@defproc[(start-server
          [#:port port exact-nonnegative-integer? 8080]
          [#:public-dir public-dir (or/c string? path?) "public"]
          [#:api api (listof route?) '()]
          [#:events events (or/c #f event-bus?) #f]
          [#:api-token api-token (or/c #f string?) #f]
          [#:capability capability (or/c #f capability?) #f]
          [#:serve-api-client? serve-api-client? boolean? #t])
         (values exact-nonnegative-integer? procedure?)]{
Starts the loopback HTTP server that powers the embedded frontend. Static
resources, SPA index fallback, JSON routes, generated API client, and optional
SSE event stream share the same origin. The return values are the actual port
and a shutdown procedure. @racket[start-dev-server] remains a compatibility
alias for this low-level server primitive; it does not define a browser-based
application mode.

The low-level server requires an explicit, non-empty @racket[#:api-token] whenever
@racket[#:capability] is supplied, keeping runtime authority bound to the
embedded WebView rather than an unauthenticated loopback caller.
}

@defproc[(stop-server [shutdown-proc procedure?]) void?]{Stops the server.}

@defproc[(open-browser [url string?]) void?]{
Explicitly opens an external URL in the user's default browser. This helper is
appropriate for documentation, OAuth, support pages, and similar external
resources. @racket[run-app], @racket[open-window], and @racket[open-webview]
do not use it as a fallback.
}

@section[#:tag "js-bridge"]{JavaScript Bridge}

@defmodule*[(glaze/api glaze/api-macros)]

The embedded frontend calls Racket through ordinary same-origin HTTP requests.
This keeps the bridge easy to inspect and test with normal developer tools.

@defproc[(GET [path string?]
              [handler procedure?]
              [#:permission permission (or/c #f symbol? string?) #f]
              [#:resource resource (or/c #f procedure?) #f]) route?]{}
@defproc[(POST [path string?]
               [handler procedure?]
               [#:permission permission (or/c #f symbol? string?) #f]
               [#:resource resource (or/c #f procedure?) #f]) route?]{}
@defproc[(PUT [path string?]
              [handler procedure?]
              [#:permission permission (or/c #f symbol? string?) #f]
              [#:resource resource (or/c #f procedure?) #f]) route?]{}
@defproc[(DELETE [path string?]
                 [handler procedure?]
                 [#:permission permission (or/c #f symbol? string?) #f]
                 [#:resource resource (or/c #f procedure?) #f]) route?]{}

The resource procedure receives the same request and captured path parameters
as the route handler. Its result is checked against the active scoped
permission before the handler can run. @racket[define-api-routes] accepts the
same @racket[#:permission] and @racket[#:resource] options after its route path.

@section[#:tag "capabilities"]{Runtime Capabilities}

@defmodule[glaze/capability]

@defproc[(make-capability [id string?] [permissions list?]) capability?]{
Creates a named authority from permission identifiers and scoped permissions.
}

@defproc[(allow-permission [id (or/c symbol? string?)]) any/c]{Creates an
unscoped permission grant. A bare symbol or string in
@racket[make-capability] has the same meaning.}

@defproc[(scoped-permission [id (or/c symbol? string?)]
                            [authorize procedure?]) any/c]{Creates a generic
resource permission. @racket[authorize] receives the route resource and must
return a true value to authorize the request.}

@defproc[(path-permission [id (or/c symbol? string?)]
                          [#:allow allow-roots list?]
                          [#:deny deny-roots list? '()]) any/c]{
Allows resources inside the listed roots except those inside a denied root.
Paths are simplified through existing symlinks; deny entries take precedence.
The checked resource may be one path or a non-empty list of paths; every path
in a list must be authorized.
}

@defproc[(url-permission [id (or/c symbol? string?)]
                         [#:allow allowed-patterns list?]
                         [#:deny denied-patterns list? '()]) any/c]{
Allows URL resources that match an exact string or an explicitly supplied
regular expression. Deny patterns take precedence. Strings never gain implicit
wildcards.
}

@defproc[(command-permission [id (or/c symbol? string?)]
                             [#:allow allow-programs list?]
                             [#:deny deny-programs list? '()]
                             [#:arguments arguments-ok? procedure?
                              (lambda (arguments) #t)]) any/c]{
Allows exact executable names or paths and optionally validates their argument
list. Deny entries take precedence.
}

@defproc[(command-resource [program path-string?]
                           [arguments list?]) command-resource?]{Constructs the
resource returned by a command route's @racket[#:resource] procedure.}

@defproc[(capability-authorized? [capability capability?]
                                 [permission (or/c symbol? string?)]
                                 [resource any/c #f]) boolean?]{Checks runtime
authority without invoking a route.}

@defparam[current-capability-id id (or/c #f string?)]{Bound to the active
capability ID while a protected route handler or resource extractor runs.}

@defparam[current-capability-authorizer authorize (or/c #f procedure?)]{
Bound to the active capability's authorizer while a protected route resource
extractor or handler runs. This permits a handler to authorize resources that
are only discovered during execution, such as HTTP redirect targets.}

@defproc[(current-capability-authorized? [permission (or/c symbol? string?)]
                                         [resource any/c #f]) boolean?]{Checks
the dynamically active capability. Returns false outside a protected route.}

@section[#:tag "filesystem"]{Scoped Filesystem}

@defmodule[glaze/filesystem]

@defproc[(make-filesystem-routes [#:prefix prefix string? "api/fs"])
         (listof route?)]{
Creates frontend routes for text and binary file I/O, directories, metadata,
existence checks, file copy, move, and removal. The routes declare
@racket['fs:read] or @racket['fs:write]; use @racket[path-permission] grants in
the active capability. Copy and move expose both paths as one resource, so both
source and destination must be in scope.

The default prefix generates client functions such as
@litchar{glaze.api.fsReadText}, @litchar{glaze.api.fsWriteFile}, and
@litchar{glaze.api.fsMove}. Binary payloads use base64 strings in JSON.
}

@defproc[(fs-read-text [path path-string?]) string?]{}
@defproc[(fs-write-text! [path path-string?] [text string?]) void?]{Writes via a
same-directory temporary file and atomic replacement.}
@defproc[(fs-read-bytes [path path-string?]) bytes?]{}
@defproc[(fs-write-bytes! [path path-string?] [data bytes?]) void?]{Writes via a
same-directory temporary file and atomic replacement.}
@defproc[(fs-read-dir [path path-string?]) (listof hash?)]{}
@defproc[(fs-create-dir! [path path-string?]
                         [#:recursive? recursive? boolean? #t]) void?]{}
@defproc[(fs-remove! [path path-string?]
                     [#:recursive? recursive? boolean? #f]) void?]{}
@defproc[(fs-copy! [source path-string?]
                   [destination path-string?]
                   [#:replace? replace? boolean? #f]) void?]{}
@defproc[(fs-move! [source path-string?]
                   [destination path-string?]
                   [#:replace? replace? boolean? #f]) void?]{}
@defproc[(fs-stat [path path-string?]) hash?]{}
@defproc[(fs-exists? [path path-string?]) boolean?]{}

@section[#:tag "shell"]{Scoped Shell and Child Processes}

@defmodule[glaze/shell]

@defproc[(make-shell-routes [#:prefix prefix string? "api/shell"]
                            [#:max-output max-output exact-positive-integer? (* 1024 1024)]
                            [#:max-processes max-processes exact-positive-integer? 32]
                            [#:cwd-roots cwd-roots (listof path-string?) '()]
                            [#:allow-environment allowed-environment list? '()]
                            [#:retention-seconds retention-seconds positive-real? 300])
         (listof route?)]{
Creates frontend routes for direct command execution. @racket['shell:execute]
authorizes @racket[command-resource] values before synchronous or background
execution; @racket['shell:manage] authorizes background status, stdin, and kill
operations. Handles are additionally bound to the capability that spawned
them. Programs are never passed through a system shell. Frontend working
directories and environment-variable names are denied by default; applications
must opt in with @racket[cwd-roots] and @racket[allowed-environment]. The
registry retains at most @racket[max-processes] handles, evicting completed
handles first.

The default prefix generates @litchar{glaze.api.shellOutput},
@litchar{shellSpawn}, @litchar{shellStatus}, @litchar{shellWrite},
@litchar{shellCloseStdin}, and @litchar{shellKill}. Completed handles remain
available for @racket[retention-seconds].
}

@defproc[(shell-output [program path-string?]
                       [arguments (listof string?) '()]
                       [#:cwd cwd (or/c #f path-string?) #f]
                       [#:env environment (or/c #f hash?) #f]
                       [#:timeout timeout (or/c #f positive-real?) 30]
                       [#:max-output max-output exact-positive-integer? (* 1024 1024)])
         hash?]{Executes a program directly, closes stdin, waits up to the
timeout, and returns exit status plus bounded UTF-8 stdout and stderr.}

@defproc[(shell-spawn! [program path-string?]
                       [arguments (listof string?) '()]
                       [#:cwd cwd (or/c #f path-string?) #f]
                       [#:env environment (or/c #f hash?) #f]
                       [#:max-output max-output exact-positive-integer? (* 1024 1024)])
         shell-process?]{Starts a background child process without invoking a
system shell.}
@defproc[(shell-process-id [child shell-process?]) string?]{}
@defproc[(shell-process-pid [child shell-process?]) exact-integer?]{}
@defproc[(shell-process-info [child shell-process?]) hash?]{}
@defproc[(shell-process-write! [child shell-process?]
                               [data (or/c string? bytes?)]) void?]{}
@defproc[(shell-process-close-input! [child shell-process?]) void?]{}
@defproc[(shell-process-kill! [child shell-process?]
                              [force? boolean? #t]) void?]{}
@defproc[(shell-process-wait [child shell-process?]
                             [timeout (or/c #f nonnegative-real?) #f]) boolean?]{}

@section[#:tag "store"]{Persistent JSON Store}

@defmodule[glaze/store]

@defproc[(make-store-routes [#:root root path-string?]
                            [#:prefix prefix string? "api/store"]
                            [#:defaults defaults hash? (hasheq)]
                            [#:auto-save auto-save (or/c boolean? nonnegative-real?) 100]
                            [#:events events (or/c #f event-bus?) #f])
         (listof route?)]{
Creates capability-gated frontend routes for persistent JSON key-value stores.
Read operations declare @racket['store:read] and mutations declare
@racket['store:write]. Frontend paths must be relative and cannot escape the
required @racket[root]. Mutations optionally publish
@racket['store:change] on @racket[events]. Auto-save uses a debounce interval in
milliseconds; @racket[#f] disables it.

The generated client includes @litchar{storeLoad}, @litchar{storeGet},
@litchar{storeSet}, @litchar{storeHas}, @litchar{storeDelete},
@litchar{storeClear}, @litchar{storeReset}, @litchar{storeKeys},
@litchar{storeValues}, @litchar{storeEntries}, @litchar{storeLength},
@litchar{storeSave}, @litchar{storeReload}, and @litchar{storeClose}.
}

@defproc[(load-store [path path-string?]
                     [#:defaults defaults hash? (hasheq)]
                     [#:auto-save auto-save (or/c boolean? nonnegative-real?) 100]
                     [#:create-new? create-new? boolean? #f]
                     [#:override-defaults? override-defaults? boolean? #f])
         store?]{Loads a JSON object from disk or creates an in-memory store
from defaults. The file is created on the first save.}
@defproc[(store-get [storage store?]
                    [key (or/c string? symbol?)]
                    [default any/c #f]) any/c]{}
@defproc[(store-set! [storage store?]
                     [key (or/c string? symbol?)]
                     [value jsexpr?]) void?]{}
@defproc[(store-has-key? [storage store?]
                         [key (or/c string? symbol?)]) boolean?]{}
@defproc[(store-delete! [storage store?]
                        [key (or/c string? symbol?)]) boolean?]{}
@defproc[(store-clear! [storage store?]) void?]{}
@defproc[(store-reset! [storage store?]) void?]{}
@defproc[(store-keys [storage store?]) (listof string?)]{}
@defproc[(store-values [storage store?]) list?]{}
@defproc[(store-entries [storage store?]) list?]{}
@defproc[(store-count [storage store?]) exact-nonnegative-integer?]{}
@defproc[(store-snapshot [storage store?]) hash?]{}
@defproc[(store-save! [storage store?]) void?]{}
@defproc[(store-reload! [storage store?]
                        [#:ignore-defaults? ignore-defaults? boolean? #f]) void?]{}
@defproc[(store-close! [storage store?]) void?]{}

@section[#:tag "system-plugins"]{Capability-Gated System Plugins}

@defmodule[glaze/system]

@defproc[(make-system-routes [#:prefix prefix string? "api/system"])
         (listof route?)]{
Creates frontend routes for clipboard text, desktop notifications, opening or
revealing paths, opening URLs, and OS information. The routes use distinct
permissions: @racket['clipboard:read], @racket['clipboard:write],
@racket['notification:send], @racket['opener:open-path],
@racket['opener:reveal-path], @racket['opener:open-url], @racket['os:read],
and @racket['os:hostname]. Path operations should use @racket[path-permission]
grants and URL opening should use @racket[url-permission]. Resource scopes are
checked before native handlers run.

The default prefix generates @litchar{systemClipboardRead},
@litchar{systemClipboardWrite}, @litchar{systemNotificationSend},
@litchar{systemOpenerOpenPath}, @litchar{systemOpenerRevealPath},
@litchar{systemOpenerOpenUrl}, @litchar{systemOsInfo}, and
@litchar{systemOsHostname}.
}

@defproc[(system-information) hash?]{Returns platform, OS type, family,
architecture, executable extension, locale, and the runtime-reported system
version string.}
@defproc[(system-hostname) string?]{Returns the local host name. Frontend access
uses the separate @racket['os:hostname] permission.}

@section[#:tag "paths"]{Application and Resource Paths}

@defmodule[glaze/path]

@defproc[(make-path-resolver [app-id string?]
                             [#:resource-root resource-root path-string?]
                             [#:app-directories-override overrides
                              (or/c #f path-string? hash?) #f])
         path-resolver?]{
Creates a resolver for Tauri-style application directories. A path override
uses one portable root: config/data/local-data use the root, cache uses its
@litchar{caches} child, and log uses @litchar{logs}. A hash may override
@racket['config], @racket['data], @racket['localData], @racket['cache], and
@racket['log] individually. Overrides accept the documented @litchar{$HOME},
@litchar{$DATA}, @litchar{$LOCALDATA}, and other base-directory variables.
}

@defproc[(make-path-routes [#:app-id app-id string?]
                           [#:resource-root resource-root path-string?]
                           [#:app-directories-override overrides
                            (or/c #f path-string? hash?) #f]
                           [#:prefix prefix string? "api/path"])
         (listof route?)]{
Creates granular, default-deny frontend routes for application/user/resource
directories and path utilities. Resource resolution is confined to the
configured resource root even through existing symbolic links.
}

@defproc[(app-config-dir [resolver path-resolver?]) path?]{}
@defproc[(app-data-dir [resolver path-resolver?]) path?]{}
@defproc[(app-local-data-dir [resolver path-resolver?]) path?]{}
@defproc[(app-cache-dir [resolver path-resolver?]) path?]{}
@defproc[(app-log-dir [resolver path-resolver?]) path?]{}
@defproc[(resource-dir [resolver path-resolver?]) path?]{}
@defproc[(resolve-resource [resolver path-resolver?]
                           [relative-path path-string?]) path?]{}
@defproc[(path-join [path path-string?] ...) path?]{}
@defproc[(path-resolve [path path-string?] ...) path?]{}
@defproc[(path-normalize [path path-string?]) path?]{}
@defproc[(path-basename [path path-string?]) string?]{}
@defproc[(path-dirname [path path-string?]) string?]{}
@defproc[(path-extname [path path-string?]) string?]{}
@defproc[(path-absolute? [path path-string?]) boolean?]{}

@section[#:tag "http-client"]{Scoped HTTP Client}

@defmodule[glaze/http]

@defproc[(http-request [url string?]
                       [#:method method (or/c string? symbol? bytes?) "GET"]
                       [#:headers headers hash? (hasheq)]
                       [#:body body (or/c #f string? bytes?) #f]
                       [#:timeout timeout real? 30]
                       [#:max-request-bytes max-request-bytes exact-positive-integer?
                        (* 10 1024 1024)]
                       [#:max-response-bytes max-response-bytes exact-positive-integer?
                        (* 10 1024 1024)]
                       [#:max-redirects max-redirects exact-nonnegative-integer? 5]
                       [#:authorize-url? authorize-url? procedure?
                        (lambda (candidate) #t)])
         hash?]{
Performs a bounded HTTP or HTTPS request and returns the status, final URL,
headers, UTF-8 replacement-decoded text, and base64 body. The timeout is a
total deadline across redirects. Every URL, including every redirect target,
is checked before connecting. Cross-origin redirects remove
@litchar{Authorization} and @litchar{Cookie}.}

@defproc[(make-http-routes [#:prefix prefix string? "api/http"]
                           [#:max-request-bytes max-request-bytes
                            exact-positive-integer? (* 10 1024 1024)]
                           [#:max-response-bytes max-response-bytes
                            exact-positive-integer? (* 10 1024 1024)]
                           [#:timeout timeout real? 30]
                           [#:max-redirects max-redirects
                            exact-nonnegative-integer? 5])
         (listof route?)]{
Creates @racket['http:request]-protected frontend access. The generated client
contains @litchar{glaze.api.httpRequest}. Initial and redirected URLs are
checked against the active URL-scoped capability before connecting. Frontend
callers may lower configured limits but cannot raise them. Connection-managed
headers such as @litchar{Host} and @litchar{Content-Length} are rejected.}

@section[#:tag "sqlite"]{Scoped SQLite}

@defmodule[glaze/sql]

@defproc[(open-sqlite-database [path path-string?]
                               [#:busy-retry-limit busy-retry-limit
                                exact-nonnegative-integer? 1000])
         sql-database?]{Opens or creates a SQLite database. The parent
directory must already exist.}

@defproc[(sql-select [database sql-database?]
                     [statement string?]
                     [parameters list? '()]
                     [#:max-rows max-rows exact-positive-integer? 10000]
                     [#:max-cell-bytes max-cell-bytes exact-positive-integer?
                      (* 10 1024 1024)])
         (listof hash?)]{
Runs a parameterized @litchar{SELECT} or @litchar{WITH} query. Results are
bounded by row count. SQL NULL becomes JSON null and BLOB values become hashes
containing @racket['blobBase64].}

@defproc[(sql-execute! [database sql-database?]
                       [statement string?]
                       [parameters list? '()])
         hash?]{Runs a parameterized statement and returns
@racket['rowsAffected] and @racket['lastInsertId].}

@defproc[(sql-close! [database sql-database?]) void?]{Closes the connection.
Repeated close calls are harmless.}

@defproc[(make-sql-routes [#:root root path-string?]
                          [#:prefix prefix string? "api/sql"]
                          [#:max-connections max-connections
                           exact-positive-integer? 16]
                          [#:max-rows max-rows exact-positive-integer? 10000]
                          [#:max-cell-bytes max-cell-bytes exact-positive-integer?
                           (* 10 1024 1024)]
                          [#:busy-retry-limit busy-retry-limit
                           exact-nonnegative-integer? 1000])
         (listof route?)]{
Creates @racket['sql:load], @racket['sql:select], @racket['sql:execute], and
@racket['sql:close] protected routes. Database paths are relative to
@racket[root], are checked through existing symbolic links, and connections
are cached separately for each active capability. The generated client
contains @litchar{sqlLoad}, @litchar{sqlSelect}, @litchar{sqlExecute}, and
@litchar{sqlClose}.}

A route handler receives the web-server request followed by any captured
@litchar{:param} path values. Returning a jsexpr produces a JSON 200 response;
a full response value may also be returned, including a streaming response
(@racket[streaming-response] / @racket[event-stream-response] below).

@defproc[(request-json-body [req request?]) jsexpr?]{
Parses a JSON request body. Missing, empty, or malformed input yields an empty
hash so route validation can produce a clean client error. JSON object keys in
Racket jsexprs are symbols, for example @racket[(hash-ref body 'delta)].
}

@defproc[(json-response [data jsexpr?]) response?]{}
@defproc[(api-response [data jsexpr?]) response?]{}
@defproc[(error-response [status exact-nonnegative-integer?]
                         [message string?]) response?]{}

@defproc[(streaming-response [writer (-> output-port? any)]
                             [#:mime mime bytes? #"application/octet-stream"]
                             [#:headers headers (listof header?) '()])
         response?]{
A chunked 200 response. @racket[writer] runs on the connection thread after
the status line and headers go out — the same mechanism as the built-in
@litchar{/glaze/events} SSE endpoint. Write to the port and call
@racket[(flush-output out)] after each chunk that should be delivered
immediately; returning from the writer ends the response.

A handler that raises before returning still maps to a 500 JSON (nothing is
on the wire yet); an exception @emph{inside} the writer closes the
connection mid-stream, so wrap your own errors there if truncation is
unacceptable. The typical use is proxying a streaming LLM endpoint — tokens
reach the page as they arrive, API keys stay in Racket, and the page never
makes a cross-origin call:

@codeblock|{
(GET "api/llm/chat"
 (lambda (req)
   (streaming-response
    #:mime #"application/x-ndjson"
    (lambda (out)
      (for ([delta (in-llm-deltas (request-json-body req))])
        (displayln (jsexpr->string (hasheq 'delta delta)) out)
        (flush-output out))))))
}|
}

@defproc[(event-stream-response [sender procedure?]
                                [#:headers headers (listof header?) '()])
         response?]{
The SSE flavor of @racket[streaming-response]: @racket[sender] receives a
@racket[send] callback, and each @racket[(send name data)] emits one
@verbatim|{event: name\ndata: <json>}| frame and flushes. Consuming with
@racket[EventSource] in the page works out of the box;
@racket[Cache-Control: no-cache] is added automatically.

@codeblock|{
(GET "api/sse/demo"
 (lambda (req)
   (event-stream-response
    (lambda (send)
      (send 'delta (hasheq 'text "Hel"))
      (send 'delta (hasheq 'text "lo"))
      (send 'done (hasheq 'ok #t))))))
}|
}

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
          [#:window-state window-state (or/c #f path-string?) #f]
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
          [#:window-state window-state (or/c #f path-string?) #f]
          [#:on-close on-close (-> any) (lambda () (void))])
         webview?]{
Lower-level synonym of @racket[open-window] with the same fail-fast contract.
}

@defproc[(webview-window-state [webview webview?])
         (or/c #f window-state?)]{
Returns the native window's outer position, size, and maximized state.
}

@defproc[(webview-set-window-state! [webview webview?]
                                    [state window-state?])
         any]{
Moves/resizes the native window and restores its maximized state.
}

@defproc[(webview-save-state! [webview webview?] [path path-string?])
         (or/c #f path?)]{}

@defproc[(webview-restore-state! [webview webview?] [path path-string?])
         any]{
Reads a saved state, clamps it to @racket[webview-screen-area], and applies it.
Malformed or missing state files are ignored.
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

With @racket[#:capability], the server additionally enforces named permissions
and resource scopes. Routes without @racket[#:permission], routes whose
permission is absent, and resources outside a granted scope return 403 before
the handler runs. Grant @racket['glaze:events] to authorize the SSE endpoint.

This is defense in depth against casual local callers, not isolation from
other processes running as the same OS user.

@section[#:tag "update-checks"]{Update Checks}

@defmodule[glaze/update]

@defproc[(check-update [manifest-url string?]
                        [#:current-version current-version string? "0.0.0"])
         (or/c #f hash?)]{
Checks a JSON manifest for a newer version. An optional @litchar{sha256} field
is passed through for artifact verification. Absolute and relative redirects
are followed for at most ten hops.
}
@defproc[(newer-version? [candidate string?] [current string?]) boolean?]{}
@defproc[(verify-file-sha256 [path (or/c string? path?)]
                             [expected-hex string?]) boolean?]{
Returns @racket[#t] only for a verified digest; @racket[#f] also covers cases
where verification could not be performed.
}

For installed applications, the signed updater is the preferred path. An
@racket[update-manifest] binds the application id, SemVer version, release
channel, minimum supported version, staged rollout percentage, and a set of
platform/architecture @racket[update-artifact] values into one Ed25519-signed
payload. Artifact records include a bounded size, SHA-256 digest, installer
kind and arguments, and an optional second Ed25519 signature.

@defproc[(fetch-update-manifest [manifest-url string?]
                                [public-key path-string?]
                                [#:key-id key-id (or/c #f string?) #f]
                                [#:maximum-bytes maximum-bytes exact-positive-integer?
                                 (* 1024 1024)])
         update-manifest?]{
Downloads an HTTPS manifest with a hard byte limit and verifies its signature.
If @racket[key-id] is provided, a valid signature from any other release key
is rejected. Redirects are followed for at most ten hops, and every target
must remain HTTPS.
}

@defproc[(select-update [config updater-config?]
                        [manifest update-manifest?])
         (or/c #f update-candidate?)]{
Checks application identity, channel, exact SemVer precedence, minimum version,
rollout bucket, platform, and architecture.
}

@defproc[(download-update [config updater-config?]
                          [candidate update-candidate?]
                          [destination path-string?])
         path?]{
Downloads to a partial file over HTTPS, enforces the configured maximum and
signed artifact size, verifies SHA-256 plus the optional artifact signature,
then atomically renames the verified file into place. Redirects are followed
for at most ten hops, and every target must remain HTTPS.
}

@defproc[(make-install-plan [candidate update-candidate?]
                            [downloaded-path path-string?]
                            [#:backup-path backup-path (or/c #f path-string?) #f]
                            [#:install install procedure?]
                            [#:restart restart procedure? void]
                            [#:rollback rollback procedure? void])
         install-plan?]{}

@defproc[(make-replace-install-plan [candidate update-candidate?]
                                    [downloaded-path path-string?]
                                    [target-path path-string?]
                                    [#:backup-path backup-path path-string?]
                                    [#:restart restart procedure? void])
         install-plan?]{
Creates the atomic portable-artifact strategy, suitable for AppImage-style or
self-contained deployments. Native installers use @racket[make-install-plan]
with a platform adapter that owns elevation and process handoff.
}

@defproc[(execute-install-plan! [plan install-plan?]) any]{
Runs install and restart. If installation raises and the signed manifest allows
rollback, the rollback callback runs before the original exception is raised.
}

Release automation can validate and sign a payload with
@exec{raco glaze manifest-sign}, then verify the wrapper and pinned key id with
@exec{raco glaze manifest-verify}.

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

@defmodule*[(glaze/deeplink glaze/autolaunch)]

@defproc[(ensure-url-scheme! [scheme string?]
                             [#:app-name app-name string? scheme])
         any/c]{
Windows registers a user-scope URL protocol, Linux writes a desktop entry and
uses @exec{xdg-mime} when available, and macOS URL schemes are declared in the
bundle at build time.
}

@defproc[(auto-launch-set! [name string?] [enabled? boolean?]) void?]{}
@defproc[(auto-launch-enabled? [name string?]) any/c]{}

@section{Packaging}

@defmodule[glaze/build]

@defproc[(build-app
          [#:entry entry (or/c string? path?) "main.rkt"]
          [#:name name (or/c #f string?) #f]
          [#:version version (or/c #f string?) #f]
          [#:publisher publisher (or/c #f string?) #f]
          [#:identifier identifier (or/c #f string?) #f]
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

The publisher is written to native installer metadata. Keep the identifier
stable across releases: it deterministically defines the WiX UpgradeCode and
the NSIS Add/Remove Programs identity.
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
