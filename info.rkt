#lang info

;; Single installable multi-collection package. Runtime dependencies belong in
;; `deps`; test and documentation tooling stays in `build-deps` so a future
;; binary distribution does not require developer-only libraries.

(define name "glaze")
(define collection 'multi)

(define deps
  '(["base" #:version "8.0"]
    "web-server"
    "web-server-lib"))

(define build-deps
  '("rackunit-lib"
    "scribble-lib"
    "racket-doc"))

;; Glaze is authored and published as Racket source. Catalog/build services may
;; derive built/binary packages for a specific Racket version afterwards.
(define distribution-preference 'source)

;; `raco-commands` and `scribblings` are collection-level fields in
;; glaze-cli/info.rkt and glaze-doc/info.rkt.

;; Racket's valid-version? treats "0.7" as the appropriate package version
;; spelling for this release line.
(define version "0.7")

(define pkg-desc
  "Lisp-native framework for modern desktop applications with Racket and native WebViews")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)
(define repository "https://github.com/turinglambdaai/glaze")
