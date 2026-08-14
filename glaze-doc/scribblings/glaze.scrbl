#lang scribble/manual

@title{Glaze}
@author{turinglambdaai}

Build desktop apps with Racket backend and web frontend.

@section{Quick Start}

@verbatim{
 $ raco pkg install glaze
 $ raco glaze init myapp
 $ cd myapp
 $ racket main.rkt
}

@section{Core API}

@defmodule[glaze/server]

@defproc[(start-server
          [#:port port exact-nonnegative-integer? 8080]
          [#:public-dir public-dir (or/c string? path?) "public"])
         (values exact-nonnegative-integer? procedure?)]{
Starts a local HTTP server on @racket[127.0.0.1] serving static files from
@racket[public-dir]. Returns the requested port and a shutdown procedure.
@racket[start-dev-server] is a backward-compatible alias.
}

@defproc[(stop-server [shutdown-proc procedure?]) void?]{
Stops the dev server.
}

@defmodule[glaze/browser]

@defproc[(open-browser [url string?]) void?]{
Opens the system browser to the given URL.
}

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
(@racket[NSWindow] + @racket[WKWebView] via objc FFI, verified), Windows
(WebView2 via COM FFI, in progress), Linux (WebKitGTK, scaffolded). When the
native backend is unavailable, @racket[open-window] returns @racket[#f] so
callers can fall back to @racket[open-browser].

@defproc[(open-window
          [url string?]
          [#:title title string? "Glaze"]
          [#:width width exact-positive-integer? 1024]
          [#:height height exact-positive-integer? 768]
          [#:on-close on-close (-> any) (lambda () (void))])
         (or/c webview? #f)]{
Opens the window and loads @racket[url]. @racket[on-close] runs when the
window closes (programmatic @racket[webview-close] or the user closing it).
Returns @racket[#f] when the backend is unavailable.
}

@defproc[(webview-navigate [wv webview?] [url string?]) void?]{
Loads a new URL into an open webview.
}

@defproc[(webview-close [wv webview?]) void?]{
Closes the window and stops its event pump.
}

@section{Packaging}

@defmodule[glaze/build]

@defproc[(build-app
          [#:entry entry (or/c string? path?) "main.rkt"]
          [#:name name (or/c #f string?) #f]
          [#:icon icon (or/c #f path?) #f]
          [#:out-dir out-dir (or/c string? path?) "dist"]
          [#:embed-dlls? embed-dlls? boolean? #f]
          [#:installer? installer? boolean? #f])
         path?]{
Builds a Glaze project into a distributable directory via @racket[raco exe]
+ @racket[raco distribute], bundling the project's @racket[public/] next to
the executable. On macOS, post-processes the resulting @tt{.app} bundle's
@tt{Info.plist}. When @racket[installer?] is true, also produces a platform
installer (msi / dmg / AppImage), falling back to a zip / tar.gz when the
native toolchain is absent.
}

@section{CLI Commands}

@verbatim{
 raco glaze init <name>   Create a new project
 raco glaze dev           Start dev server
 raco glaze build         Build a distributable (+ optional installer)
}
