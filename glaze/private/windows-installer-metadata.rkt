#lang racket/base

;; Deterministic Windows installer identity and source templates. Toolchain
;; execution remains in glaze/build.

(require file/sha1
         racket/file
         racket/path
         racket/string)

(provide stable-upgrade-code
         windows-wxs
         windows-nsis
         text->rtf
         project-license-text
         default-license-notice
         dmg-style-applescript)

(define (stable-upgrade-code identifier)
  (define digest (subbytes (sha1-bytes (open-input-string identifier)) 0 16))
  (bytes-set! digest 6 (bitwise-ior #x50 (bitwise-and #x0f (bytes-ref digest 6))))
  (bytes-set! digest 8 (bitwise-ior #x80 (bitwise-and #x3f (bytes-ref digest 8))))
  (define hex (string-upcase (bytes->hex-string digest)))
  (format "{~a-~a-~a-~a-~a}"
          (substring hex 0 8)
          (substring hex 8 12)
          (substring hex 12 16)
          (substring hex 16 20)
          (substring hex 20 32)))

(define (xml-escape value)
  (for/fold ([result value])
            ([replacement
              (in-list
               '(("&" . "&amp;") ("<" . "&lt;") (">" . "&gt;") ("'" . "&apos;") ("\"" . "&quot;")))])
    (string-replace result (car replacement) (cdr replacement))))

;; Minimal WiX v4 source referencing the dist directory contents. The wizard
;; UI (welcome, license agreement, install directory, progress, exit) comes
;; from the UI extension; the exit page offers launching the app through the
;; Util extension's WixShellExec. Optional paths (license RTF, wizard
;; bitmaps) ride in as WixVariables; omitted ones keep the wizard defaults.
(define (windows-wxs app-name
                     dist-dir
                     version
                     publisher
                     identifier
                     #:license-rtf [license-rtf #f]
                     #:banner-bmp [banner-bmp #f]
                     #:dialog-bmp [dialog-bmp #f])
  (define dist (xml-escape (path->string dist-dir)))
  (define (wix-variable id path)
    (if path
        (format "    <WixVariable Id='~a' Value='~a' />\n" id (xml-escape (path->string path)))
        ""))
  (format
   #<<WXEOF
<?xml version='1.0' encoding='utf-8'?>
<Wix xmlns='http://wixtoolset.org/schemas/v4/wxs' xmlns:ui='http://wixtoolset.org/schemas/v4/wxs/ui'>
  <Package Name='~a' Manufacturer='~a' Version='~a' UpgradeCode='~a' Scope='perMachine'>
    <MajorUpgrade DowngradeErrorMessage='A newer version is already installed.' />
    <MediaTemplate EmbedCab='yes' />
    <Feature Id='Main'>
      <ComponentGroupRef Id='ProductComponents' />
      <ComponentGroupRef Id='ShortcutComponents' />
    </Feature>
~a~a~a    <Property Id='WIXUI_INSTALLDIR' Value='INSTALLDIR' />
    <Property Id='WIXUI_EXITDIALOGOPTIONALCHECKBOXTEXT' Value='Launch ~a' />
    <Property Id='WixShellExecTarget' Value='[INSTALLDIR]~a.exe' />
    <CustomAction Id='LaunchApplication' BinaryRef='Wix4UtilCA_~a' DllEntry='WixShellExec' Impersonate='yes' />
    <ui:WixUI Id='WixUI_InstallDir' />
    <UI>
      <Publish Dialog='ExitDialog' Control='Finish' Event='DoAction' Value='LaunchApplication' Condition='WIXUI_EXITDIALOGOPTIONALCHECKBOX = 1 and NOT Installed' Order='2' />
    </UI>
  </Package>
  <Fragment>
    <StandardDirectory Id='ProgramFiles64Folder'>
      <Directory Id='INSTALLDIR' Name='~a' />
    </StandardDirectory>
    <StandardDirectory Id='ProgramMenuFolder'>
      <Directory Id='ApplicationProgramsFolder' Name='~a' />
    </StandardDirectory>
    <StandardDirectory Id='DesktopFolder' />
  </Fragment>
  <Fragment>
    <ComponentGroup Id='ShortcutComponents' Directory='ApplicationProgramsFolder'>
      <Component Id='StartMenuShortcutComponent' Guid='*'>
        <Shortcut Id='StartMenuApplicationShortcut' Name='~a' Target='[INSTALLDIR]~a.exe' WorkingDirectory='INSTALLDIR' />
        <RemoveFolder Id='RemoveApplicationProgramsFolder' Directory='ApplicationProgramsFolder' On='uninstall' />
        <RegistryValue Root='HKCU' Key='Software\~a\Shortcuts' Name='StartMenu' Type='integer' Value='1' KeyPath='yes' />
      </Component>
      <Component Id='DesktopShortcutComponent' Guid='*' Directory='DesktopFolder'>
        <Shortcut Id='DesktopApplicationShortcut' Name='~a' Target='[INSTALLDIR]~a.exe' WorkingDirectory='INSTALLDIR' />
        <RegistryValue Root='HKCU' Key='Software\~a\Shortcuts' Name='Desktop' Type='integer' Value='1' KeyPath='yes' />
      </Component>
    </ComponentGroup>
  </Fragment>
  <Fragment>
    <ComponentGroup Id='ProductComponents' Directory='INSTALLDIR'>
      <Files Include='~a\**' />
    </ComponentGroup>
  </Fragment>
</Wix>
WXEOF
   (xml-escape app-name)
   (xml-escape publisher)
   (xml-escape version)
   (stable-upgrade-code identifier)
   (wix-variable "WixUILicenseRtf" license-rtf)
   (wix-variable "WixUIBannerBmp" banner-bmp)
   (wix-variable "WixUIDialogBmp" dialog-bmp)
   (xml-escape app-name) ; license checkbox label
   (xml-escape app-name) ; shell-exec target
   (if (equal? (system-type 'arch) 'aarch64) "ARM64" "X64")
   (xml-escape app-name) ; install directory name
   (xml-escape app-name) ; start-menu folder name
   (xml-escape app-name) ; start-menu shortcut name
   (xml-escape app-name) ; start-menu shortcut target
   (xml-escape identifier) ; start-menu registry key
   (xml-escape app-name) ; desktop shortcut name
   (xml-escape app-name) ; desktop shortcut target
   (xml-escape identifier) ; desktop registry key
   dist ; harvested payload
   ))

;; ---- wizard license page ----

(define default-license-notice
  "This software is distributed under the terms of its accompanying license. The complete license text ships with the application. By continuing the installation you accept those terms.")

(define (rtf-escape-char ch)
  (define code (char->integer ch))
  (case ch
    [(#\\) "\\\\"]
    [(#\{) "\\{"]
    [(#\}) "\\}"]
    [(#\newline) "\\par\n"]
    [(#\return) ""]
    [(#\tab) "\\tab "]
    [else
     (cond
       [(< code 128) (string ch)]
       ;; RTF \uN takes a signed 16-bit code unit.
       [(<= code #xFFFF)
        (format "\\u~a?"
                (if (>= code #x8000)
                    (- code #x10000)
                    code))]
       [else
        (define value (- code #x10000))
        (format "\\u~a?\\u~a?"
                (+ #xD800 (quotient value #x400))
                (+ #xDC00 (remainder value #x400)))])]))

(define (text->rtf text)
  (string-append
   "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss\\fcharset0 Segoe UI;}}\\fs18 "
   (apply string-append (map rtf-escape-char (string->list text)))
   "\\par}"))

(define (project-license-text project-dir)
  (and project-dir
       (for/or ([name (in-list '("LICENSE" "LICENSE.txt" "COPYING" "COPYING.txt"))])
         (define candidate (build-path project-dir name))
         (and (file-exists? candidate)
              (with-handlers ([exn:fail? (lambda (_) #f)])
                (file->string candidate))))))

;; ---- branded DMG layout ----

(define dmg-window-origin-x 200)
(define dmg-window-origin-y 120)
(define dmg-window-width 660)
(define dmg-window-height 400)
(define dmg-icon-size 80)
(define dmg-app-icon-position '(130 . 160))
(define dmg-applications-icon-position '(450 . 160))

(define (applescript-escape value)
  (regexp-replace* #px"[\\\\\"]" value (lambda (m) (string-append "\\" m))))

;; The volume style can only be authored through Finder's AppleScript
;; interface (.DS_Store icon views have no hdiutil switches). Window bounds
;; are screen coordinates; icon positions are window coordinates.
(define (dmg-style-applescript disk-name app-name)
  (define bottom-right
    (format "{~a, ~a, ~a, ~a}"
            dmg-window-origin-x
            dmg-window-origin-y
            (+ dmg-window-origin-x dmg-window-width)
            (+ dmg-window-origin-y dmg-window-height)))
  (format (string-append
           "tell application \"Finder\"\n"
           "\ttell disk \"~a\"\n"
           "\t\topen\n"
           "\t\tset current view of container window to icon view\n"
           "\t\tset statusbar visible of container window to false\n"
           "\t\tset theViewOptions to the icon view options of container window\n"
           "\t\tset arrangement of theViewOptions to not arranged\n"
           "\t\tset icon size of theViewOptions to ~a\n"
           "\t\tset background picture of theViewOptions to file \".background:background.png\"\n"
           "\t\tset bounds of container window to ~a\n"
           "\t\tset position of item \"~a\" of container window to {~a, ~a}\n"
           "\t\tset position of item \"Applications\" of container window to {~a, ~a}\n"
           "\t\tclose\n"
           "\t\tupdate\n"
           "\tend tell\n"
           "end tell\n")
          (applescript-escape disk-name)
          dmg-icon-size
          bottom-right
          (applescript-escape app-name)
          (car dmg-app-icon-position)
          (cdr dmg-app-icon-position)
          (car dmg-applications-icon-position)
          (cdr dmg-applications-icon-position)))

;; NSIS supports silent installation via /S. The ARP keys below make install,
;; upgrade, and uninstall detection work for winget and Windows Settings.
(define (nsis-escape value)
  (string-replace (string-replace value "$" "$$") "\"" "$\\\""))

(define (windows-nsis app-name dist-dir version publisher identifier)
  (format
   #<<NSI
Unicode True
Name "~a"
OutFile "~a\~a-setup.exe"
RequestExecutionLevel admin
SetRegView 64
InstallDir "$PROGRAMFILES64\~a"
InstallDirRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "InstallLocation"
Page directory
Page instfiles
UninstPage instfiles
Section "Install"
  SetOutPath "$INSTDIR"
  File /r /x "*.msi" /x "*-setup.exe" /x "*.wxs" /x "*.nsi" "~a\*.*"
  CreateShortcut "$DESKTOP\~a.lnk" "$INSTDIR\~a.exe"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "DisplayName" "~a"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "DisplayVersion" "~a"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "Publisher" "~a"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "DisplayIcon" "$INSTDIR\~a.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a" "NoRepair" 1
SectionEnd
Section "Uninstall"
  Delete "$DESKTOP\~a.lnk"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\~a"
SectionEnd
NSI
   (nsis-escape app-name)
   (path->string dist-dir)
   (nsis-escape app-name)
   (nsis-escape app-name)
   (nsis-escape identifier)
   (path->string dist-dir)
   (nsis-escape app-name)
   (nsis-escape app-name)
   (nsis-escape identifier)
   (nsis-escape app-name)
   (nsis-escape identifier)
   (nsis-escape version)
   (nsis-escape identifier)
   (nsis-escape publisher)
   (nsis-escape identifier)
   (nsis-escape identifier)
   (nsis-escape app-name)
   (nsis-escape identifier)
   (nsis-escape identifier)
   (nsis-escape identifier)
   (nsis-escape identifier)
   (nsis-escape app-name)
   (nsis-escape identifier)))
