#lang info

(define collection "glaze-test")
(define deps
  '(["base" #:version "8.0"]
    "glaze-lib"
    "rackunit-lib"))
(define build-deps
  '())
(define pkg-desc "Tests for Glaze")
(define pkg-authors '(jrtxio))
(define license 'MIT)
