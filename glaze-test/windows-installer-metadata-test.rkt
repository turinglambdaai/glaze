#lang racket/base

(require rackunit
         racket/file
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

(test-case "the MSI authors the commercial wizard and desktop integration"
  (define identifier "com.acme.demo")
  (define wxs (windows-wxs "Demo" (string->path "C:/dist") "1.2.3" "Acme" identifier))
  (check-true (string-contains? wxs "ui:WixUI Id='WixUI_InstallDir'")
              "the wizard must come from the UI extension namespace")
  (check-true (string-contains? wxs "xmlns:ui='http://wixtoolset.org/schemas/v4/wxs/ui'"))
  (check-true (string-contains? wxs "WIXUI_INSTALLDIR' Value='INSTALLDIR'"))
  (check-true (string-contains? wxs "WIXUI_EXITDIALOGOPTIONALCHECKBOXTEXT' Value='Launch Demo'")
              "the finish page must offer launching the app")
  (check-true (string-contains? wxs "WixShellExecTarget' Value='[INSTALLDIR]Demo.exe'"))
  (check-true (string-contains? wxs "DllEntry='WixShellExec'")
              "the launch action must come from the Util extension")
  (check-true (string-contains? wxs "WIXUI_EXITDIALOGOPTIONALCHECKBOX = 1 and NOT Installed")
              "the checkbox must launch only on a fresh install")
  (check-true (string-contains? wxs "StartMenuApplicationShortcut")
              "a start-menu shortcut must be authored")
  (check-true (string-contains? wxs "DesktopShortcutComponent")
              "a desktop shortcut must be authored")
  (check-false (string-contains? wxs "WixUILicenseRtf")
               "wizard bitmaps and license stay unauthored when unconfigured"))

(test-case "configured wizard assets ride in through WixVariables"
  (define wxs (windows-wxs "Demo" (string->path "C:/dist") "1.2.3" "Acme" "com.acme.demo"
                           #:license-rtf (string->path "C:/branding/license.rtf")
                           #:banner-bmp (string->path "C:/branding/banner.bmp")
                           #:dialog-bmp (string->path "C:/branding/dialog.bmp")))
  (check-true (string-contains? wxs "WixVariable Id='WixUILicenseRtf' Value='C:/branding/license.rtf'"))
  (check-true (string-contains? wxs "WixVariable Id='WixUIBannerBmp' Value='C:/branding/banner.bmp'"))
  (check-true (string-contains? wxs "WixVariable Id='WixUIDialogBmp' Value='C:/branding/dialog.bmp'")))

(test-case "the license RTF renderer stays ASCII with unicode escapes"
  (define rtf (text->rtf "Demo License\nsecond line with ünïcode ✓\ttabbed"))
  (check-true (string-prefix? rtf "{\\rtf1\\ansi")
              "the generated license must be RTF")
  (check-true (string-contains? rtf "Demo License\\par")
              "license line breaks must become RTF paragraph breaks")
  (check-true (string-contains? rtf "\\u252?")
              "non-ASCII license characters must become unicode escapes")
  (check-false (string-contains? rtf "ünïcode")
               "the generated RTF must stay ASCII so WiX never re-decodes it")
  (check-true (string-contains? rtf "\\tab ")
              "tabs must render as RTF tab escapes"))

(test-case "the repository license text renders automatically"
  (define root (make-temporary-file "glaze-installer-test-~a" 'directory))
  (call-with-output-file (build-path root "LICENSE")
    #:exists 'truncate/replace
    (lambda (out) (display "Demo License Text\n" out)))
  (check-equal? (project-license-text root) "Demo License Text\n")
  (check-false (project-license-text (build-path root "missing")))
  (delete-directory/files root))

(test-case "the DMG layout script addresses the resolved disk and both icons"
  (define script (dmg-style-applescript "Smoke App" "Smoke.app"))
  (check-true (string-contains? script "tell disk \"Smoke App\"")
              "the script must address the volume by name")
  (check-true (regexp-match?
               #rx"set background picture of theViewOptions to file \"[.]background:background[.]png\""
               script)
              "the background must come from the hidden .background folder")
  (check-true (string-contains? script "set position of item \"Smoke.app\" of container window")
              "the bundle icon must be positioned")
  (check-true (string-contains? script "set position of item \"Applications\" of container window")
              "the Applications link must be positioned")
  (check-true (string-contains? script "set bounds of container window to {200, 120, 860, 520}")
              "the window must match the branded background geometry")
  (check-true (string-contains? script "set statusbar visible of container window to false")
              "the item-count status bar must stay out of the artwork")
  (check-true (regexp-match? #rx"tell disk \"Smoke \\\\\"App\\\\\"\""
                             (dmg-style-applescript "Smoke \"App\"" "Smoke.app"))
              "quotes in display names must be AppleScript-escaped"))
