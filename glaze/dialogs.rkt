#lang racket/base

;; Native file/folder dialogs, three platforms:
;;   macOS   — NSOpenPanel / NSSavePanel via objc FFI
;;   Windows — GetOpenFileNameW / GetSaveFileNameW for files and
;;             SHBrowseForFolderW for directories
;;   Linux   — zenity or kdialog subprocesses
;;
;; Contract: #f (or an empty list for pick-files) means user cancellation.

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
         ;; pure helpers, exported for regression tests
         win-filter-string
         wstr
         wstr-parts)

;; ---- common validation ----

(define (valid-filter? f)
  (and (list? f)
       (pair? f)
       (string? (car f))
       (andmap string? (cdr f))))

(define (check-dialog-args who title directory filters [default-name #f])
  (unless (or (not title) (string? title))
    (raise-argument-error who "(or/c #f string?)" title))
  (unless (or (not directory) (path? directory) (string? directory))
    (raise-argument-error who "(or/c #f path? string?)" directory))
  (unless (and (list? filters) (andmap valid-filter? filters))
    (raise-argument-error who "list of (list name pattern ...) strings" filters))
  (unless (or (not default-name) (string? default-name))
    (raise-argument-error who "(or/c #f string?)" default-name)))

;; ---- UTF-16 plumbing (Windows wide strings) ----

;; platform string -> NUL-terminated UTF-16LE bytes. Use a fresh converter per
;; call: dialog APIs can be invoked from different Racket threads and converter
;; state is not a useful process-global resource.
(define (wstr s)
  (unless (string? s)
    (raise-argument-error 'wstr "string?" s))
  (define cv (bytes-open-converter "UTF-8" "UTF-16LE"))
  (define in (string->bytes/utf-8 s))
  (define-values (out consumed status) (bytes-convert cv in))
  (bytes-close-converter cv)
  (unless (and (eq? status 'complete) (= consumed (bytes-length in)))
    (error 'wstr "UTF-16 conversion failed"))
  (bytes-append out (bytes 0 0)))

(define (utf16-nul-at? b i)
  (and (<= (+ i 1) (sub1 (bytes-length b)))
       (zero? (bytes-ref b i))
       (zero? (bytes-ref b (+ i 1)))))

(define (decode-utf16 b start end)
  (define cv (bytes-open-converter "UTF-16LE" "UTF-8"))
  (define-values (out consumed status) (bytes-convert cv (subbytes b start end)))
  (bytes-close-converter cv)
  (unless (eq? status 'complete)
    (error 'wstr-parts "invalid UTF-16 buffer"))
  (bytes->string/utf-8 out))

;; Windows multi-select buffers are a UTF-16 multi-string:
;;   directory NUL file1 NUL file2 NUL NUL
;; A single selection is simply path NUL NUL. A single NUL separates entries;
;; an empty next entry (double NUL) terminates the list.
(define (wstr-parts b)
  (unless (bytes? b)
    (raise-argument-error 'wstr-parts "bytes?" b))
  (define len (bytes-length b))
  (let loop ([start 0] [acc '()])
    (cond
      [(>= (+ start 1) len) (reverse acc)]
      [(utf16-nul-at? b start) (reverse acc)]
      [else
       (define end
         (let find ([i start])
           (cond
             [(>= (+ i 1) len) len]
             [(utf16-nul-at? b i) i]
             [else (find (+ i 2))])))
       (define piece (decode-utf16 b start end))
       (define next (+ end 2))
       (if (or (>= (+ next 1) len) (utf16-nul-at? b next))
           (reverse (cons piece acc))
           (loop next (cons piece acc)))])))

;; ---- platform dispatch ----

(define (dialog-supported?)
  (case (system-type 'os)
    [(macosx) (and appkit #t)]
    [(windows) (and comdlg32 shell32 #t)]
    [else (and (or (find-executable-path "zenity" #f)
                   (find-executable-path "kdialog" #f))
               #t)]))

;; ---- macOS (AppKit) ----

(define appkit
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "/System/Library/Frameworks/AppKit.framework/AppKit")))

(import-class NSOpenPanel NSSavePanel NSURL NSArray NSString NSMutableArray)

(define (->nsstring s)
  (tell (tell NSString alloc) initWithUTF8String: #:type _string s))

(define NSModalResponseOK 1)

(define (as-path p)
  (if (string? p) (string->path p) p))

(define (configure-panel! panel title directory filters)
  (when title (tellv panel setTitle: (->nsstring title)))
  (when (and directory (directory-exists? (as-path directory)))
    (tellv panel setDirectoryURL: #:type _id
           (tell NSURL fileURLWithPath: #:type _id
                 (->nsstring (path->string (as-path directory))))))
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
  (tellv panel setAllowsMultipleSelection: #:type _bool multiple?)
  (define response (tell #:type _int panel runModal))
  (and (= response NSModalResponseOK)
       (let ()
         (define urls (tell #:type _id panel URLs))
         (define n (tell #:type _int urls count))
         (filter values
                 (for/list ([i (in-range n)])
                   (define p
                     (nsurl->path
                      (tell #:type _id urls objectAtIndex: #:type _int i)))
                   (and p (string->path p)))))))

(define (mac-save title default-name directory filters)
  (define panel (tell NSSavePanel savePanel))
  (configure-panel! panel title directory filters)
  (when (and default-name (non-empty-string? default-name))
    (tellv panel setNameFieldStringValue: (->nsstring default-name)))
  (define response (tell #:type _int panel runModal))
  (and (= response NSModalResponseOK)
       (let ([p (nsurl->path (tell #:type _id panel URL))])
         (and p (string->path p)))))

;; ---- Windows ----

(define comdlg32
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "comdlg32")))

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
(define OFN_EXPLORER #x00080000)
(define OFN_OVERWRITEPROMPT #x00000002)

(define shell32
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "shell32")))
(define ole32
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "ole32")))

(define-cstruct _BROWSEINFOW
  ([hwndOwner _pointer]
   [pidlRoot _pointer]
   [pszDisplayName _pointer]
   [lpszTitle _pointer]
   [ulFlags _uint32]
   [lpfn _pointer]
   [lParam _intptr]
   [iImage _int]))

(define SHBrowseForFolderW
  (and shell32
       (get-ffi-obj "SHBrowseForFolderW" shell32
                    (_fun _BROWSEINFOW-pointer -> _pointer)
                    (lambda () #f))))
(define SHGetPathFromIDListW
  (and shell32
       (get-ffi-obj "SHGetPathFromIDListW" shell32
                    (_fun _pointer _pointer -> _bool)
                    (lambda () #f))))
(define CoTaskMemFree
  (and ole32
       (get-ffi-obj "CoTaskMemFree" ole32
                    (_fun _pointer -> _void)
                    (lambda () #f))))

(define BIF_RETURNONLYFSDIRS #x00000001)

(define (win-pick-folder title _directory)
  (unless (and SHBrowseForFolderW SHGetPathFromIDListW)
    (error 'pick-folder "Windows Shell folder dialog unavailable"))
  (define display-buffer (make-bytes (* 2 260)))
  (define path-buffer (make-bytes (* 2 32768)))
  (define title-buffer (and title (wstr title)))
  (define bi
    (make-BROWSEINFOW #f #f display-buffer title-buffer
                      BIF_RETURNONLYFSDIRS #f 0 0))
  (define pidl (SHBrowseForFolderW bi))
  (and pidl
       (dynamic-wind
         void
         (lambda ()
           (and (SHGetPathFromIDListW pidl path-buffer)
                (let ([parts (wstr-parts path-buffer)])
                  (and (pair? parts) (string->path (first parts))))))
         (lambda ()
           (when CoTaskMemFree (CoTaskMemFree pidl))))))

(define GetOpenFileNameW
  (and comdlg32
       (get-ffi-obj "GetOpenFileNameW" comdlg32
                    (_fun _OPENFILENAMEW-pointer -> _bool)
                    (lambda () #f))))
(define GetSaveFileNameW
  (and comdlg32
       (get-ffi-obj "GetSaveFileNameW" comdlg32
                    (_fun _OPENFILENAMEW-pointer -> _bool)
                    (lambda () #f))))

(define (win-filter-string filters)
  (string-append
   (string-join
    (append
     (for/list ([f (in-list filters)])
       (format "~a\0~a\0" (car f) (string-join (cdr f) ";")))
     '("All files\0*.*\0"))
    "")
   "\0"))

(define (copy-initial-name! buffer default-name)
  (when (and default-name (non-empty-string? default-name))
    (define encoded (wstr default-name))
    (when (> (bytes-length encoded) (bytes-length buffer))
      (raise-arguments-error 'save-file-dialog
                             "default filename is too long for the Windows dialog buffer"
                             "default-name" default-name))
    (bytes-copy! buffer 0 encoded)))

(define (win-open-dialog! title directory filters multiple? _folder? save? default-name)
  (define getter (if save? GetSaveFileNameW GetOpenFileNameW))
  (unless getter (error 'pick-file "comdlg32 unavailable"))
  ;; lpstrFile must point at storage whose actual allocation matches nMaxFile.
  ;; Always pass the large buffer and copy the optional default name into it;
  ;; passing a small encoded default string with nMaxFile=32768 would let the
  ;; native API write beyond the allocation.
  (define file-buffer (make-bytes (* 2 32768)))
  (copy-initial-name! file-buffer default-name)
  (define ofn
    (make-OPENFILENAMEW
     (ctype-sizeof _OPENFILENAMEW)
     #f #f
     (wstr (win-filter-string filters))
     #f 0 0
     file-buffer
     (quotient (bytes-length file-buffer) 2)
     #f 0
     (and directory (wstr (path->string (as-path directory))))
     (and title (wstr title))
     (bitwise-ior (if multiple? (bitwise-ior OFN_ALLOWMULTISELECT OFN_EXPLORER) 0)
                  (if save? OFN_OVERWRITEPROMPT 0))
     0 0 #f #f #f #f #f 0 0))
  (and (getter ofn)
       (let ([parts (wstr-parts file-buffer)])
         (cond
           [(and multiple? (> (length parts) 1))
            (define dir (path->directory-path (first parts)))
            (for/list ([n (in-list (rest parts))]) (build-path dir n))]
           [else
            (for/list ([p (in-list parts)]) (string->path p))]))))

;; ---- Linux ----

(define (run-dialog-capture exe args)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define out (open-output-string))
    (define code
      (parameterize ([current-output-port out])
        (apply system*/exit-code exe args)))
    (and (= code 0)
         (let ([s (string-trim (get-output-string out))])
           (and (non-empty-string? s) s)))))

(define (zenity-filters filters)
  (append-map
   (lambda (f)
     (list "--file-filter"
           (format "~a | ~a" (car f) (string-join (cdr f) " "))))
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
     (define start
       (cond
         [(and directory default-name)
          (path->string (build-path (as-path directory) default-name))]
         [directory (if (path? directory) (path->string directory) directory)]
         [default-name default-name]
         [else "."]))
     (define args
       (append
        (cond
          [folder? (list "--getexistingdirectory" start)]
          [save? (list "--getsavefilename" start (kdialog-filter filters))]
          [multiple? (list "--getopenfilename" start "--multiple"
                           (kdialog-filter filters))]
          [else (list "--getopenfilename" start (kdialog-filter filters))])
        (if title (list "--title" title) '())))
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

(define (check-support! who)
  (unless (dialog-supported?)
    (error who "no file dialog backend on this platform")))

(define (pick-file #:title [title #f]
                   #:directory [directory #f]
                   #:filters [filters '()])
  (check-dialog-args 'pick-file title directory filters)
  (check-support! 'pick-file)
  (case (system-type 'os)
    [(macosx) (unwrap-single (mac-pick title directory filters #f #f))]
    [(windows) (unwrap-single (win-open-dialog! title directory filters #f #f #f #f))]
    [else (unwrap-single (lin-dialog title directory filters #f #f #f #f))]))

(define (pick-files #:title [title #f]
                    #:directory [directory #f]
                    #:filters [filters '()])
  (check-dialog-args 'pick-files title directory filters)
  (check-support! 'pick-files)
  (case (system-type 'os)
    [(macosx) (or (mac-pick title directory filters #t #f) '())]
    [(windows) (or (win-open-dialog! title directory filters #t #f #f #f) '())]
    [else (or (lin-dialog title directory filters #t #f #f #f) '())]))

(define (pick-folder #:title [title #f]
                     #:directory [directory #f])
  (check-dialog-args 'pick-folder title directory '())
  (check-support! 'pick-folder)
  (case (system-type 'os)
    [(macosx) (unwrap-single (mac-pick title directory '() #f #t))]
    [(windows) (win-pick-folder title directory)]
    [else (unwrap-single (lin-dialog title directory '() #f #t #f #f))]))

(define (save-file-dialog #:title [title #f]
                          #:default-name [default-name #f]
                          #:directory [directory #f]
                          #:filters [filters '()])
  (check-dialog-args 'save-file-dialog title directory filters default-name)
  (check-support! 'save-file-dialog)
  (case (system-type 'os)
    [(macosx) (mac-save title default-name directory filters)]
    [(windows) (win-open-dialog! title directory filters #f #f #t default-name)]
    [else (unwrap-single
           (lin-dialog title directory filters #f #f #t default-name))]))
