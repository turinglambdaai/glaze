#lang info

(define collection 'multi)
(define deps
  '(["base" #:version "8.0"]
    "glaze-lib"
    "glaze-cli"
    "glaze-doc"))
(define build-deps
  '("glaze-test"))
(define pkg-desc "Build desktop apps with Racket backend and web frontend — a Tauri-like framework for Racket")
(define pkg-authors '(jrtxio))
(define license 'MIT)
(define repository "https://github.com/jrtxio/glaze")
