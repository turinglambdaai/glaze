#lang info

(define collection "glaze")
(define deps
  '(["base" #:version "8.0"]
    "web-server"
    "web-server-lib"))
(define build-deps
  '("rackunit-lib"))
(define pkg-desc "Core library for Glaze — build desktop apps with Racket backend and web frontend")
(define pkg-authors '(jrtxio))
(define license 'MIT)
