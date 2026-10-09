#lang racket/base

(require racket/file
         racket/list
         racket/port
         racket/string
         racket/system
         rackunit
         glaze/build)

;; ---- package name / version sanitization ----

(check-equal? (sanitize-package-name "My App!") "my-app")
(check-equal? (sanitize-package-name "Notes++") "notes++")
(check-equal? (sanitize-package-name " Glaze ") "glaze")
(check-equal? (sanitize-package-name "---") "app" "a name with no legal characters falls back")
(check-equal? (sanitize-package-version "1.0.0-beta") "1.0.0.beta")
(check-equal? (sanitize-package-version "0.0.1") "0.0.1")
(check-equal? (sanitize-package-version "") "0.0.0")

(check-not-false (member (deb-arch-name) '("amd64" "arm64" "all")))
(check-not-false (member (rpm-arch-name) '("x86_64" "aarch64" "noarch")))

;; ---- metadata text ----

(check-true (string-contains? (deb-control "Test App" "1.2.3" "Turing Lambda" "amd64")
                              "Package: test-app"))
(check-true (string-contains? (deb-control "Test App" "1.2.3" "Turing Lambda" "amd64")
                              "Version: 1.2.3"))
(check-true (string-contains? (deb-control "Test App" "1.2.3" "Turing Lambda" "amd64")
                              "Architecture: amd64"))
(check-true (string-contains? (deb-control "Test App" "1.2.3" "" "amd64")
                              "Maintainer: Unknown maintainer"))

(check-true (string-contains? (desktop-entry "Notes") "Name=Notes"))
(check-true (string-contains? (desktop-entry "Notes") "Exec=Notes"))
(check-true (string-contains? (desktop-entry "Notes") "Type=Application"))

(define spec (rpm-spec "Test App" "1.0.0" "Turing Lambda" (string->path "/tmp/stage")))
(check-true (string-contains? spec "Name: test-app"))
(check-true (string-contains? spec "Version: 1.0.0"))
(check-true (string-contains? spec "/usr/bin/Test App"))
(check-true (string-contains? spec "/usr/lib/Test App"))
(check-true (string-contains? spec "cp -a /tmp/stage/usr %{buildroot}/"))
(check-true (string-contains? spec "/usr/share/icons/hicolor/64x64/apps/test-app.png")
            "the icon is declared so rpm accepts every installed file")

;; ---- generated placeholder icon ----

(define png (icon-png-bytes))
(check-equal? (subbytes png 0 8) #"\211PNG\r\n\032\n" "PNG signature")
(check-equal? (subbytes png 8 12) (bytes 0 0 0 13) "IHDR length is 13")
(check-equal? (subbytes png 12 16) #"IHDR")
(check-equal? (subbytes png 16 20) (bytes 0 0 0 64) "width 64")
(check-equal? (subbytes png 20 24) (bytes 0 0 0 64) "height 64")
(check-equal? (subbytes png 24 29) (bytes 8 2 0 0 0) "8-bit RGB, no interlace")

;; Walk the chunk structure; the IDAT zlib stream uses stored deflate
;; blocks whose LEN/NLEN must complement, and the trailing adler32 must
;; match the reconstructed raw scanlines.
(define (chunks bs)
  (let loop ([offset 8])
    (cond
      [(>= offset (bytes-length bs)) '()]
      [else
       (define len (integer-bytes->integer (subbytes bs offset (+ offset 4)) #f #t))
       (define type (subbytes bs (+ offset 4) (+ offset 8)))
       (define data (subbytes bs (+ offset 8) (+ offset 8 len)))
       (cons (cons type data) (loop (+ offset 12 len)))])))

(define parsed (chunks png))
(check-equal? (length parsed) 3 "IHDR, IDAT, IEND")
(check-equal? (car (last parsed)) #"IEND")

(define idat (cdr (second parsed)))
(check-equal? (subbytes idat 0 2) (bytes #x78 #x01) "zlib header, fastest mode")
;; Rebuild the raw scanlines from the stored blocks and verify adler32.
(define-values (raw adler-at-end)
  (let loop ([offset 2]
             [acc '()]
             [raw-len 0])
    (define bfinal (bytes-ref idat offset))
    (define len (+ (bytes-ref idat (+ offset 1)) (* 256 (bytes-ref idat (+ offset 2)))))
    (define nlen (+ (bytes-ref idat (+ offset 3)) (* 256 (bytes-ref idat (+ offset 4)))))
    (check-equal? nlen (bitwise-and #xFFFF (bitwise-not len)) "NLEN complements LEN")
    (define block (subbytes idat (+ offset 5) (+ offset 5 len)))
    (define acc2 (cons block acc))
    (define len2 (+ raw-len len))
    (if (bitwise-and bfinal 1)
        (values (apply bytes-append (reverse acc2))
                (integer-bytes->integer (subbytes idat (+ offset 5 len) (+ offset 9 len)) #f #t))
        (loop (+ offset 5 len) acc2 len2))))
(check-equal? (bytes-length raw) (* 64 (+ 1 (* 64 3))) "64 filtered RGB scanlines")
;; Known adler32 vector: "Wikipedia" -> 0x11E60398.
(define (adler32 data)
  (define mod 65521)
  (let loop ([i 0]
             [a 1]
             [b 0])
    (if (= i (bytes-length data))
        (+ (* (modulo b mod) 65536) (modulo a mod))
        (let ([a2 (modulo (+ a (bytes-ref data i)) mod)]) (loop (add1 i) a2 (modulo (+ b a2) mod))))))
(check-equal? (adler32 (string->bytes/utf-8 "Wikipedia")) #x11E60398 "known adler32 vector")
(check-equal? (adler32 raw) adler-at-end "zlib adler32 covers the raw scanlines")

;; ---- real deb build (only where dpkg-deb exists) ----

(when (find-executable-path "dpkg-deb" #f)
  (define dist (make-temporary-file "glaze-pkgtest-dist-~a" 'directory))
  (make-directory* (build-path dist "bin"))
  (make-directory* (build-path dist "lib"))
  (call-with-output-file (build-path dist "bin" "pkgtest")
                         (lambda (out) (display "#!/bin/sh\necho ok\n" out))
                         #:exists 'replace)
  (file-or-directory-permissions (build-path dist "bin" "pkgtest") #o755)
  (call-with-output-file (build-path dist "lib" "data.txt")
                         (lambda (out) (display "payload" out))
                         #:exists 'replace)
  (define artifact
    (make-linux-installer dist "pkgtest" "0.4.2" "Turing Lambda" "TuringLambda.Glaze.PkgTest"))
  (check-not-false artifact "packaging produced an artifact")
  (define deb-path (build-path dist "pkgtest.deb"))
  (check-true (file-exists? deb-path) "the deb artifact exists")
  (when (file-exists? deb-path)
    (check-true (> (file-size deb-path) 0))
    ;; dpkg-deb --info / --contents validate the structure for real.
    (define info
      (with-output-to-string (lambda ()
                               (system* (find-executable-path "dpkg-deb" #f) "--info" deb-path))))
    (check-true (string-contains? info "Package: pkgtest"))
    (check-true (string-contains? info "Version: 0.4.2"))
    (define contents
      (with-output-to-string (lambda ()
                               (system* (find-executable-path "dpkg-deb" #f) "--contents" deb-path))))
    (check-true (string-contains? contents "usr/bin/pkgtest") "wrapper is packaged")
    (check-true (string-contains? contents "usr/lib/pkgtest/lib/data.txt") "payload is packaged")
    (check-true (string-contains? contents "usr/share/applications/pkgtest.desktop"))
    (check-true (string-contains? contents "usr/share/icons/hicolor/64x64/apps/pkgtest.png")))
  (delete-directory/files dist))

;; ---- real rpm build (only where rpmbuild exists) ----

(when (find-executable-path "rpmbuild" #f)
  (define dist (make-temporary-file "glaze-rpmtest-dist-~a" 'directory))
  (make-directory* (build-path dist "bin"))
  (call-with-output-file (build-path dist "bin" "rpmtest")
                         (lambda (out) (display "#!/bin/sh\necho ok\n" out))
                         #:exists 'replace)
  (file-or-directory-permissions (build-path dist "bin" "rpmtest") #o755)
  (define artifact
    (make-linux-installer dist "rpmtest" "0.4.2" "Turing Lambda" "TuringLambda.Glaze.RpmTest"))
  (define rpm-path (build-path dist "rpmtest.rpm"))
  (check-true (file-exists? rpm-path) "the rpm artifact exists")
  (when (file-exists? rpm-path)
    (define listing
      (with-output-to-string (lambda () (system* (find-executable-path "rpm" #f) "-qpl" rpm-path))))
    (check-true (string-contains? listing "usr/bin/rpmtest"))
    (check-true (string-contains? listing "usr/lib/rpmtest")))
  (delete-directory/files dist))
