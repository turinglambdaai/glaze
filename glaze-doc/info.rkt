#lang info

(define collection "glaze-doc")
(define deps
  '(["base" #:version "8.0"]
    "scribble-lib"
    "glaze-lib"))
(define build-deps
  '("racket-doc"
    "scribble-lib"))
(define pkg-desc "Documentation for Glaze")
(define pkg-authors '(jrtxio))
(define license 'MIT)
(define scribblings '(("scribblings/glaze.scrbl" () (library))))
