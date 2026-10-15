#lang racket/base

(require rackunit
         racket/string
         glaze/private/windows-installer-metadata)

(test-case "Windows upgrade identity is stable and application-specific"
  (define identifier "com.acme.demo")
  (define first (stable-upgrade-code identifier))
  (check-equal? first (stable-upgrade-code identifier))
  (check-not-equal? first (stable-upgrade-code "com.acme.other"))
  (check-true (regexp-match? #px"^\\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\\}$"
                             first)))

(test-case "installer templates escape metadata and share the stable identity"
  (define identifier "com.acme.demo")
  (define upgrade-code (stable-upgrade-code identifier))
  (define wxs (windows-wxs "Demo & Tools" (string->path "C:/dist") "1.2.3" "A & B" identifier))
  (check-true (string-contains? wxs "Demo &amp; Tools"))
  (check-true (string-contains? wxs "A &amp; B"))
  (check-true (string-contains? wxs upgrade-code))
  (define nsi (windows-nsis "Demo" (string->path "C:/dist") "1.2.3" "Acme" identifier))
  (check-true (string-contains? nsi "DisplayVersion\" \"1.2.3"))
  (check-true (string-contains? nsi identifier)))
