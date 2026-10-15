#lang racket/base

;; Deterministic Windows installer identity and source templates. Toolchain
;; execution remains in glaze/build.

(require file/sha1
         racket/path
         racket/string)

(provide stable-upgrade-code
         windows-wxs
         windows-nsis)

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

;; Minimal WiX v4 source referencing the dist directory contents.
(define (windows-wxs app-name dist-dir version publisher identifier)
  (define dist (xml-escape (path->string dist-dir)))
  (format #<<WXEOF
<?xml version='1.0' encoding='utf-8'?>
<Wix xmlns='http://wixtoolset.org/schemas/v4/wxs'>
  <Package Name='~a' Manufacturer='~a' Version='~a' UpgradeCode='~a' Scope='perMachine'>
    <MajorUpgrade DowngradeErrorMessage='A newer version is already installed.' />
    <MediaTemplate EmbedCab='yes' />
    <StandardDirectory Id='ProgramFiles64Folder'>
      <Directory Id='INSTALLDIR' Name='~a' />
    </StandardDirectory>
    <Files Directory='INSTALLDIR' Include='~a\**' />
  </Package>
</Wix>
WXEOF
          (xml-escape app-name)
          (xml-escape publisher)
          (xml-escape version)
          (stable-upgrade-code identifier)
          (xml-escape app-name)
          dist))

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
