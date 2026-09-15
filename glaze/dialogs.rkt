#lang racket/base

;; Native file/folder dialogs, three platforms:
;;   macOS   — NSOpenPanel / NSSavePanel via objc FFI (AppKit is loaded
;;             explicitly; plain racket only links Foundation).
;;   Windows — GetOpenFileNameW / GetSaveFileNameW from comdlg32 (present on
;;             every Windows install; the Vista IFileOpenDialog COM dance
;;             buys nicer chrome, not capability).
;;   Linux   — zenity or kdialog via subprocess (the dialog front-ends of
;;             the desktop environments). When neither exists, opening a
;;             dialog RAISES — silent #f would be indistinguishable from
;;             the user cancelling; check dialog-supported? first.
;;
;; Contract: #f (or an empty list for pick-files) means the user cancelled.
;; Dialogs block the calling thread until the user picks; call from a thread
;; you can afford to park.

(require ffi/unsafe
         ffi/unsafe/objc
         racket/file
         racket/format
         racket/list
         racket/path
         racket/string
         racket/system)

(provide dialog-supported?
         pick-file
         pick-files
         pick-folder
         save-file-dialog
         ;; pure helpers, exported for the test suite
         win-filter-string
         wstr
         wstr-parts)

;; ---- UTF-16 plumbing (Windows wide strings) ----

(define utf16-converter
  (bytes-open-converter "UTF-8" "UTF-16LE"))

;; platform string -> NUL-terminated UTF-16LE bytes.
(define (wstr s)
  (define in (string->bytes/utf-8 s))
  (define-values (out consumed status)
    (bytes-convert utf16-converter in))
  (unless (and (eq? status 'complete) (= consumed (bytes-length in)))
    (error 'wstr "UTF-16 conversion failed"))
  (bytes-append out (bytes 0 0)))

;; UTF-16LE bytes -> list of strings split on NUL code units (2 zero bytes —
;; unit-aware, so paths containing code units like U+0100 split correctly).
(define (wstr-parts b)
  (define cv (bytes-open-converter "UTF-16LE" "UTF-8"))
  (let loop ([i 0] [acc '()])
    (if (>= (+ i 1) (bytes-length b))
        (reverse acc)
        (if (and (zero? (bytes-ref b i)) (zero? (bytes-ref b (+ i 1))))
            (reverse acc) ; terminating NUL code unit
            (let ([end (let loop2 ([j i])
                         (if (and (zero? (bytes-ref b j)) (zero? (bytes-ref b (+ j 1))))
                             j
                             (loop2 (+ j 2))))])
              (define-values (out consumed status)
                (bytes-convert cv (subbytes b i end)))
              (loop (+ end 2)
                    (cons (bytes->string/utf-8 out) acc)))))))

;; ---- platform dispatch ----

(define (dialog-supported?)
  (case (system-type 'os)
    [(macosx) (and appkit #t)]
    [(windows) (and comdlg32 #t)]
    [else (and (or (find-executable-path "zenity" #f)
                   (find-executable-path "kdialog" #f))
               #t)]))

;; Filter spec: (list (list "Human name" "*.txt" "*.md") ...).

;; ---- macOS (AppKit via objc) ----

(define appkit
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "/System/Library/Frameworks/AppKit.framework/AppKit")))

(import-class NSOpenPanel NSSavePanel NSURL NSArray NSString NSMutableArray)

(define (->nsstring s)
  (tell (tell NSString alloc) initWithUTF8String: #:type _string s))

(define NSModalResponseOK 1)

(define (as-path p)
  (if (string? p) (string->path p) p))

;; Common panel configuration. NSOpenPanel subclasses NSSavePanel — every
;; setter exists on both.
(define (configure-panel! panel title directory filters)
  (when title (tellv panel setTitle: (->nsstring title)))
  (when (and directory (directory-exists? (as-path directory)))
    (tellv panel setDirectoryURL: #:type _id
           (tell NSURL fileURLWithPath: #:type _id
                 (->nsstring (path->string (as-path directory))))))
  ;; Allowed types: plain extensions ("txt", "md") work on macOS 11+.
  (define exts
    (for*/list ([f (in-list filters)]
                [pattern (in-list (cdr f))]
                #:when (regexp-match? #rx"^[*][.][^.]+$" pattern))
      (substring pattern 2)))
  (when (and (pair? exts)
             (tell panel respondsToSelector: #:type _SEL (selector setAllowedFileTypes:)))
    (define arr (tell (tell NSMutableArray alloc) init))
    (for ([e (in-list exts)])
      (tellv arr addObject: #:type _id (->nsstring e)))
    (tellv panel setAllowedFileTypes: #:type _id arr))
  panel)

(define (nsurl->path url)
  (define p (and url (tell #:type _id url path)))
  (and (cast p _id _pointer)
       (tell #:type _string p UTF8String)))

(define (mac-pick title directory filters multiple? folder?)
  (define panel (tell NSOpenPanel openPanel))
  (configure-panel! panel title directory filters)
  (tellv panel setCanChooseFiles: #:type _bool (not folder?))
  (tellv panel setCanChooseDirectories: #:type _bool folder?)
  (when multiple?
    (tellv panel setAllowsMultipleSelection: #:type _bool #t))
  (define response (tell #:type _int panel runModal))
  (and (= response NSModalResponseOK)
       (let ()
         (define urls (tell #:type _id panel URLs))
         (define n (tell #:type _int urls count))
         (for/list ([i (in-range n)])
           (define p (nsurl->path (tell #:type _id urls objectAtIndex: #:type _int i)))
           (and p (string->path p))))))

(define (mac-save title default-name directory filters)
  (define panel (tell NSSavePanel savePanel))
  (configure-panel! panel title directory filters)
  (when (and default-name (non-empty-string? default-name))
    (tellv panel setNameFieldStringValue: (->nsstring default-name)))
  (define response (tell #:type _int panel runModal))
  (and (= response NSModalResponseOK)
       (let ([p (nsurl->path (tell #:type _id panel URL))])
         (and p (string->path p)))))

;; ---- Windows (comdlg32) ----

(define comdlg32
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "comdlg32")))

;; OPENFILENAMEW — the full modern struct (unused fields passed as 0/NULL).
(define-cstruct _OPENFILENAMEW
  ([lStructSize _uint32]
   [hwndOwner _pointer]
   [hInstance _pointer]
   [lpstrFilter _pointer]
   [lpstrCustomFilter _pointer]
   [nMaxCustFilter _uint32]
   [nFilterIndex _uint32]
   [lpstrFile _pointer]
   [nMaxFile _uint32]
   [lpstrFileTitle _pointer]
   [nMaxFileTitle _uint32]
   [lpstrInitialDir _pointer]
   [lpstrTitle _pointer]
   [Flags _uint32]
   [nFileOffset _uint16]
   [nFileExtension _uint16]
   [lpstrDefExt _pointer]
   [lCustData _pointer]
   [lpfnHook _pointer]
   [lpTemplateName _pointer]
   [pvReserved _pointer]
   [dwReserved _uint32]
   [FlagsEx _uint32]))

(define OFN_ALLOWMULTISELECT #x00000200)
(define OFN_EXPLORER        #x00080000)
(define OFN_OVERWRITEPROMPT #x00000002)
(define OFN_PICKFOLDERS     #x00000020)

(define GetOpenFileNameW
  (and comdlg32 (get-ffi-obj "GetOpenFileNameW" comdlg32
                             (_fun _OPENFILENAMEW-pointer -> _bool) (lambda () #f))))
(define GetSaveFileNameW
  (and comdlg32 (get-ffi-obj "GetSaveFileNameW" comdlg32
                             (_fun _OPENFILENAMEW-pointer -> _bool) (lambda () #f))))

;; Win32 filter encoding: "name\0patterns\0" pairs, whole blob
;; double-NUL-terminated. "All files" is appended when no filter matches
;; everything, so the user is never stuck.
(define (win-filter-string filters)
  (string-append
   (string-join
    (append
     (for/list ([f (in-list filters)])
       (format "~a\0~a\0" (car f) (string-join (cdr f) ";")))
     '("All files\0*.*\0"))
    "")
   "\0"))

(define (win-open-dialog! title directory filters multiple? folder? save? default-name)
  (define getter (if save? GetSaveFileNameW GetOpenFileNameW))
  (unless getter (error 'pick-file "comdlg32 unavailable"))
  (define file-buffer (make-bytes (* 2 32768))) ; UTF-16, MAX_PATH headroom
  (define initial
    (and default-name
         (non-empty-string? default-name)
         (not directory)
         (wstr default-name)))
  (define ofn
    (make-OPENFILENAMEW
     (ctype-sizeof _OPENFILENAMEW)
     #f #f
     (wstr (win-filter-string filters))
     #f 0 0
     (or initial file-buffer)
     (quotient (bytes-length file-buffer) 2)
     #f 0
     (and directory (wstr (path->string (as-path directory))))
     (and title (wstr title))
     (bitwise-ior (if multiple? (bitwise-ior OFN_ALLOWMULTISELECT OFN_EXPLORER) 0)
                  (if folder? OFN_PICKFOLDERS 0)
                  (if save? OFN_OVERWRITEPROMPT 0))
     0 0 #f #f #f #f #f 0 0))
  (define ok? (getter ofn))
  (and ok?
       (let ()
         (define used
           (for/first ([i (in-range 0 (bytes-length file-buffer) 2)]
                       #:when (and (zero? (bytes-ref file-buffer i))
                                   (zero? (bytes-ref file-buffer (+ i 1)))))
             i))
         (define parts (wstr-parts (subbytes file-buffer 0 (or used (bytes-length file-buffer)))))
         (cond
           ;; Multi-select (explorer mode): first part = folder, rest = names.
           [(and multiple? (> (length parts) 1))
            (define dir (path->directory-path (first parts)))
            (for/list ([n (in-list (rest parts))]) (build-path dir n))]
           [else (for/list ([p (in-list parts)]) (string->path p))]))))

;; ---- Linux (zenity / kdialog) ----

(define (run-dialog-capture exe args)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define out (open-output-string))
    (define code
      (parameterize ([current-output-port out])
        (apply system*/exit-code exe args)))
    ;; 0 = picked, 1 = cancelled.
    (and (= code 0)
         (let ([s (string-trim (get-output-string out))])
           (and (non-empty-string? s) s)))))

(define (zenity-filters filters)
  (append-map
   (lambda (f) (list "--file-filter" (format "~a | ~a" (car f) (string-join (cdr f) " "))))
   filters))

(define (kdialog-filter filters)
  (format "~a|All Files"
          (string-join
           (for/list ([f (in-list filters)])
             (format "~a|~a" (string-join (cdr f) " ") (car f)))
           "\n")))

(define (lin-dialog title directory filters multiple? folder? save? default-name)
  (define zenity (find-executable-path "zenity" #f))
  (define kdialog (find-executable-path "kdialog" #f))
  (cond
    [zenity
     (define args
       (append '("--file-selection")
               (if title (list (format "--title=~a" title)) '())
               (if save? '("--save" "--confirm-overwrite") '())
               (if folder? '("--directory") '())
               (if multiple? '("--multiple" "--separator=\n") '())
               (if (and save? default-name)
                   (list (format "--filename=~a" default-name))
                   '())
               (zenity-filters filters)))
     (define s (run-dialog-capture zenity args))
     (and s
          (for/list ([line (in-list (string-split s "\n"))]
                     #:when (non-empty-string? line))
            (string->path line)))]
    [kdialog
     (define start (or directory default-name "."))
     (define args
       (append (cond
                 [folder? (list "--getexistingdirectory" start)]
                 [save? (list "--getsavefilename" start (kdialog-filter filters))]
                 [multiple? (list "--getopenfilename" start "--multiple" (kdialog-filter filters))]
                 [else (list "--getopenfilename" start (kdialog-filter filters))])
               (if title (list (format "--title ~a" title)) '())))
     (define s (run-dialog-capture kdialog args))
     (and s
          (for/list ([line (in-list (string-split s "\n"))]
                     #:when (non-empty-string? line))
            (string->path line)))]
    [else
     (error 'pick-file "no dialog tool on this Linux session (install zenity or kdialog)")]))

;; ---- public API ----

(define (unwrap-single r)
  (and r (pair? r) (first r)))

(define (check-support!)
  (unless (dialog-supported?)
    (error 'pick-file "no file dialog backend on this platform")))

;; Open one file. #f when cancelled.
(define (pick-file #:title [title #f]
                   #:directory [directory #f]
                   #:filters [filters '()])
  (check-support!)
  (case (system-type 'os)
    [(macosx) (unwrap-single (mac-pick title directory filters #f #f))]
    [(windows) (unwrap-single (win-open-dialog! title directory filters #f #f #f #f))]
    [else (unwrap-single (lin-dialog title directory filters #f #f #f #f))]))

;; Open one or more files. Returns a list (empty on cancel).
(define (pick-files #:title [title #f]
                    #:directory [directory #f]
                    #:filters [filters '()])
  (check-support!)
  (case (system-type 'os)
    [(macosx) (or (mac-pick title directory filters #t #f) '())]
    [(windows) (or (win-open-dialog! title directory filters #t #f #f #f) '())]
    [else (or (lin-dialog title directory filters #t #f #f #f) '())]))

;; Pick an existing folder. #f when cancelled.
(define (pick-folder #:title [title #f]
                     #:directory [directory #f])
  (check-support!)
  (case (system-type 'os)
    [(macosx) (unwrap-single (mac-pick title directory '() #f #t))]
    [(windows) (unwrap-single (win-open-dialog! title directory '() #f #t #f #f))]
    [else (unwrap-single (lin-dialog title directory '() #f #t #f #f))]))

;; Save-as dialog. #f when cancelled. The overwrite prompt is the dialog's;
;; no file is created here.
(define (save-file-dialog #:title [title #f]
                          #:default-name [default-name #f]
                          #:directory [directory #f]
                          #:filters [filters '()])
  (check-support!)
  (case (system-type 'os)
    [(macosx) (mac-save title default-name directory filters)]
    [(windows) (win-open-dialog! title directory filters #f #f #t default-name)]
    [else (unwrap-single (lin-dialog title directory filters #f #f #t default-name))]))
