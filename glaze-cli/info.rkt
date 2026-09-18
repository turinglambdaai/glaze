#lang info

;; Collection metadata only. Package dependencies belong to the repository
;; root info.rkt because Glaze ships as one multi-collection package.
(define collection "glaze-cli")
(define pkg-desc "CLI tools for Glaze — raco glaze commands")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)
(define raco-commands
  '(("glaze" glaze-cli/cli "create, develop, and package Glaze apps" 100)))
