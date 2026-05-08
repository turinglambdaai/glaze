#lang scribble/manual

@title{Glaze}
@author{jrtxio}

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

@defproc[(start-dev-server
          [#:port port exact-nonnegative-integer? 0]
          [#:public-dir public-dir string? "public"]
          [#:api-routes api-routes list? '()])
         (values exact-nonnegative-integer? any/c)]{
Starts a local HTTP server. Returns the actual port and a server handle.
}

@defproc[(stop-server [server any/c]) void?]{
Stops the dev server.
}

@defmodule[glaze/browser]

@defproc[(open-browser [url string?]) void?]{
Opens the system browser to the given URL.
}

@section{CLI Commands}

@verbatim{
 raco glaze init <name>   Create a new project
 raco glaze dev           Start dev server
}
