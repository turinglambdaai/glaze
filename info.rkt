#lang info

;; Single installable package: the repository root IS the package. It
;; provides every collection as a top-level directory — the `glaze`
;; library, the `raco glaze` CLI, the Scribble documentation, and the
;; test suite — so one `raco pkg install glaze` (or `--link .` from a
;; checkout) installs everything.

(define name "glaze")
(define collection 'multi)

(define deps
  '(["base" #:version "8.0"]
    "web-server"
    "web-server-lib"
    ;; Tests ship inside this package, so rackunit is a runtime dep.
    "rackunit-lib"))
(define build-deps
  '("scribble-lib"
    "racket-doc"))

;; NOTE: `raco-commands` and `scribblings` are collection-level fields:
;; they live in glaze-cli/info.rkt and glaze-doc/info.rkt respectively.

;; NOTE: Racket's `valid-version?` rejects a trailing ".0" component
;; ("0.5.0" is invalid; "0.5" is the same release).
(define version "0.5")
(define pkg-desc "Build desktop apps with Racket backend and web frontend — a Tauri-like framework for Racket")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)
(define repository "https://github.com/turinglambdaai/glaze")
