#lang racket/base

(require racket/string
         rackunit
         glaze/private/macos-bundle-metadata)

(test-case "macOS plist is deterministic and omits unused URL metadata"
  (define plist (macos-info-plist "Demo" "1.2.3"))
  (check-equal? plist (macos-info-plist "Demo" "1.2.3"))
  (check-true (string-contains? plist "<key>CFBundleExecutable</key><string>Demo</string>"))
  (check-true (string-contains? plist "<key>CFBundleVersion</key><string>1.2.3</string>"))
  (check-false (string-contains? plist "CFBundleURLTypes")))

(test-case "macOS plist preserves configured URL-scheme order"
  (define plist (macos-info-plist "Demo" "1.2.3" '(demo demo-preview)))
  (check-true (string-contains? plist "<key>CFBundleURLTypes</key>"))
  (check-true (regexp-match? #px"<string>demo</string>[\\s\\S]*<string>demo-preview</string>" plist)))
