#lang racket/base

;; Deterministic macOS bundle metadata. Filesystem assembly and signing stay
;; with the build orchestrator; this module owns only the serialized contract.

(require racket/string)

(provide macos-info-plist)

(define (macos-info-plist app-name version [url-schemes '()])
  (format #<<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>~a</string>
  <key>CFBundleDisplayName</key><string>~a</string>
  <key>CFBundleIdentifier</key><string>io.glaze.~a</string>
  <key>CFBundleExecutable</key><string>~a</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>~a</string>
  <key>CFBundleVersion</key><string>~a</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.13</string>~a
</dict>
</plist>
PLIST
          app-name
          app-name
          app-name
          app-name
          version
          version
          (if (null? url-schemes)
              ""
              (string-append "\n  <key>CFBundleURLTypes</key>\n  <array>\n    <dict>\n"
                             "      <key>CFBundleURLName</key><string>io.glaze."
                             app-name
                             "</string>\n"
                             "      <key>CFBundleURLSchemes</key>\n      <array>\n"
                             (string-join (for/list ([scheme (in-list url-schemes)])
                                            (format "        <string>~a</string>\n" scheme))
                                          "")
                             "      </array>\n    </dict>\n  </array>"))))
