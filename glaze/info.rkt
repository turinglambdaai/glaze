#lang info

;; Meta package: `raco pkg install --auto glaze` pulls in the library, the
;; raco glaze CLI, and the Scribble documentation. Provides no collections
;; itself (empty multi package); glaze-lib provides the `glaze` collection.

(define collection 'multi)

(define deps
  '(["base" #:version "8.0"]
    "glaze-lib"
    "glaze-cli"
    "glaze-doc"))
(define build-deps
  '("glaze-test"))
(define implies
  '("glaze-lib"
    "glaze-cli"
    "glaze-doc"))

(define version "0.4.0")
(define pkg-desc "Build desktop apps with Racket backend and web frontend — a Tauri-like framework for Racket")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)
(define repository "https://github.com/turinglambdaai/glaze")
