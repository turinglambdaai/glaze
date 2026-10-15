#lang racket/base

;; Deterministic Linux package metadata and the generated fallback icon. The
;; actual toolchain invocation/staging remains owned by glaze/build.

(require racket/list
         racket/path
         racket/string)

(provide deb-arch-name
         rpm-arch-name
         sanitize-package-name
         sanitize-package-version
         desktop-entry
         deb-control
         rpm-spec
         icon-png-bytes)

;; ---- shared Linux package metadata ----

;; deb Architecture / rpm BuildArch names.
(define (deb-arch-name)
  (case (system-type 'arch)
    [(x86_64 amd64) "amd64"]
    [(aarch64 arm64) "arm64"]
    [else "all"]))

(define (rpm-arch-name)
  (case (system-type 'arch)
    [(x86_64 amd64) "x86_64"]
    [(aarch64 arm64) "aarch64"]
    [else "noarch"]))

;; deb Package names are lowercase [a-z0-9+-.].
(define (sanitize-package-name app-name)
  (define lowered (string-downcase app-name))
  (define cleaned
    (regexp-replace* #rx"-*$"
                     (regexp-replace* #rx"^-*"
                                      (apply string-append
                                             (for/list ([c (in-string lowered)])
                                               (if (or (char<=? #\a c #\z)
                                                       (char<=? #\0 c #\9)
                                                       (memq c '(#\. #\+ #\-)))
                                                   (string c)
                                                   "-")))
                                      "")
                     ""))
  (if (non-empty-string? cleaned) cleaned "app"))

;; rpm Version fields reject dashes.
(define (sanitize-package-version version)
  (define cleaned
    (apply string-append
           (for/list ([c (in-string version)])
             (if (or (char-alphabetic? c) (char-numeric? c) (memq c '(#\. #\_)))
                 (string c)
                 "."))))
  (if (non-empty-string? cleaned) cleaned "0.0.0"))

;; The icon name is the hicolor/AppDir icon stem; appimagetool refuses a
;; desktop file without a resolvable Icon entry.
(define (desktop-entry app-name [icon-name #f])
  (format
   "[Desktop Entry]\nType=Application\nName=~a\nExec=~a~a\nTerminal=false\nCategories=Utility;\n"
   app-name
   app-name
   (if icon-name
       (format "\nIcon=~a" icon-name)
       "")))

(define (deb-control app-name version publisher arch)
  (format
   "Package: ~a\nVersion: ~a\nArchitecture: ~a\nMaintainer: ~a\nSection: utils\nPriority: optional\nDescription: ~a desktop application (built with Glaze)\n"
   (sanitize-package-name app-name)
   (sanitize-package-version version)
   arch
   (if (non-empty-string? publisher) publisher "Unknown maintainer")
   app-name))

(define (rpm-spec app-name version publisher staging-root)
  (format #<<SPECEOF
Name: ~a
Version: ~a
Release: 1
Summary: ~a desktop application (built with Glaze)
License: Unknown
BuildArch: ~a
%description
~a desktop application packaged by Glaze; publisher: ~a.
%prep
%build
%install
mkdir -p %{buildroot}
cp -a ~a/usr %{buildroot}/
%files
/usr/bin/~a
/usr/lib/~a
/usr/share/applications/~a.desktop
/usr/share/icons/hicolor/64x64/apps/~a.png
SPECEOF
          (sanitize-package-name app-name)
          (sanitize-package-version version)
          app-name
          (rpm-arch-name)
          app-name
          (if (non-empty-string? publisher) publisher "unknown")
          (path->string staging-root)
          app-name
          app-name
          app-name
          (sanitize-package-name app-name)))

;; ---- generated placeholder icon ----

;; A flat-color square PNG in pure Racket (zlib stored blocks + adler32):
;; projects without an icon still get a valid hicolor/AppDir icon instead
;; of a broken desktop integration or a failing appimagetool run.
(define (crc32-bytes data)
  (define table
    (for/vector #:length 256
                ([n (in-naturals)])
      (for/fold ([c n]) ([_ (in-range 8)])
        (if (zero? (bitwise-and c 1))
            (arithmetic-shift c -1)
            (bitwise-xor #xEDB88320 (arithmetic-shift c -1))))))
  (bitwise-xor #xFFFFFFFF
               (for/fold ([c #xFFFFFFFF]) ([b (in-bytes data)])
                 (bitwise-and #xFFFFFFFF (vector-ref table (bitwise-xor (bitwise-and c #xFF) b))))))

(define (adler32-bytes data)
  ;; RFC 1950: s1/s2 accumulate modulo 65521, not a 16-bit mask — masking
  ;; instead of reducing silently corrupts the checksum for larger payloads.
  (define mod 65521)
  (let loop ([i 0]
             [a 1]
             [b 0])
    (if (= i (bytes-length data))
        (+ (* (modulo b mod) 65536) (modulo a mod))
        (let ([a2 (modulo (+ a (bytes-ref data i)) mod)]) (loop (add1 i) a2 (modulo (+ b a2) mod))))))

;; zlib stream using stored (uncompressed) deflate blocks.
(define (zlib-store-bytes data)
  (define block-size 65535)
  (define blocks
    (let loop ([offset 0])
      (cond
        [(>= offset (bytes-length data)) '()]
        [else
         (define len (min block-size (- (bytes-length data) offset)))
         (define final? (>= (+ offset len) (bytes-length data)))
         (define chunk (subbytes data offset (+ offset len)))
         (cons (cons final? chunk) (loop (+ offset len)))])))
  (apply bytes-append
         (cons (bytes #x78 #x01)
               (append (for/list ([block (in-list blocks)])
                         (define final? (car block))
                         (define chunk (cdr block))
                         (define len (bytes-length chunk))
                         (bytes (if final? 1 0)
                                (bitwise-and len #xFF)
                                (arithmetic-shift (bitwise-and len #xFF00) -8)
                                (bitwise-and (bitwise-not len) #xFF)
                                (arithmetic-shift (bitwise-and (bitwise-not len) #xFF00) -8)))
                       (map cdr blocks)
                       (list (integer->integer-bytes (adler32-bytes data) 4 #f #t))))))

(define (png-chunk type data)
  (define type-bytes (string->bytes/latin-1 type))
  (define body (bytes-append type-bytes data))
  (bytes-append (integer->integer-bytes (bytes-length data) 4 #f #t)
                body
                (integer->integer-bytes (crc32-bytes body) 4 #f #t)))

(define (icon-png-bytes [size 64] [r #xC1] [g #x5F] [b #x3C])
  ;; PNG RGB scanlines are per-pixel interleaved: a filter byte, then R G B
  ;; for each pixel in the row.
  (define row (apply bytes (cons 0 (append-map (lambda (_) (list r g b)) (range size)))))
  (define raw (apply bytes-append (make-list size row)))
  (bytes-append #"\211PNG\r\n\032\n"
                (png-chunk "IHDR"
                           (bytes-append (integer->integer-bytes size 4 #f #t)
                                         (integer->integer-bytes size 4 #f #t)
                                         (bytes 8 2 0 0 0)))
                (png-chunk "IDAT" (zlib-store-bytes raw))
                (png-chunk "IEND" #"")))
