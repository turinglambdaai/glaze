#lang info

(define collection "glaze-cli")
(define deps
  '(["base" #:version "8.0"]
    "glaze-lib"))
(define build-deps
  '("rackunit-lib"))
(define pkg-desc "CLI tools for Glaze — raco glaze commands")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)
(define raco-commands
  '(("glaze" glaze-cli/cli "create and serve Glaze apps" 100)))
