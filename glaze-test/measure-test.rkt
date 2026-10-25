#lang racket/base

;; Direct contract for `raco glaze measure` (the pattern learned from
;; Rivet's measure tests): the surface is the dist/ tree, so the fixtures
;; are plain files standing in for packaged artifacts — no native
;; packaging needed. Budget files gate by glob, first match wins, and a
;; violation raises exn:fail:glaze:budget so release CI can gate
;; mechanically.

(require json
         racket/file
         racket/path
         racket/port
         racket/string
         rackunit
         glaze-cli/private/measure)

(define temp-root (make-temporary-file "glaze-measure-~a" 'directory))
(dynamic-wind
 (lambda () (void))
 (lambda ()
   (define dist (build-path temp-root "dist"))
   (make-directory* dist)
   (define (stage-artifact name bytes)
     (call-with-output-file (build-path dist name)
                            (lambda (out) (write-bytes (make-bytes bytes 65) out))))
   (stage-artifact "measured-0.1.0-macos.dmg" 3000)
   (stage-artifact "measured-0.1.0-macos-arm64.zip" 1500)
   (stage-artifact "update-stable.json" 40)

   ;; No budgets: every artifact is listed with its byte count and no
   ;; violations exist.
   (define plain (measure-size temp-root))
   (check-equal? (length (hash-ref plain 'artifacts)) 3)
   (check-equal? (hash-ref plain 'violations) '())
   (check-true (for/and ([row (in-list (hash-ref plain 'artifacts))])
                 (and (exact-positive-integer? (hash-ref row 'bytes))
                      (not (hash-ref row 'budget-bytes)))))

   ;; A budget file gates by glob, first match wins.
   (define budget-path (build-path temp-root "budgets.json"))
   (call-with-output-file budget-path
                          (lambda (out)
                            (write-json (hasheq 'rules
                                                (list (hasheq 'glob "*.dmg" 'max-bytes 2000)
                                                      (hasheq 'glob "*" 'max-bytes 100000)))
                                        out)))
   (define gated (measure-size temp-root #:budget-path budget-path))
   (check-equal? (length (hash-ref gated 'violations)) 1)
   ;; violations are (path bytes . budget) pairs
   (check-equal? (path->string (file-name-from-path (caar (hash-ref gated 'violations))))
                 "measured-0.1.0-macos.dmg")

   ;; A clean budget produces no violations.
   (define relaxed-path (build-path temp-root "budgets-relaxed.json"))
   (call-with-output-file
    relaxed-path
    (lambda (out) (write-json (hasheq 'rules (list (hasheq 'glob "*" 'max-bytes 1000000))) out)))
   (check-equal? (hash-ref (measure-size temp-root #:budget-path relaxed-path) 'violations) '())

   ;; --artifact narrows the report to one file.
   (define narrowed (measure-size temp-root #:artifact "update-stable.json"))
   (check-equal? (length (hash-ref narrowed 'artifacts)) 1)
   (check-equal? (hash-ref (car (hash-ref narrowed 'artifacts)) 'name) "update-stable.json")

   ;; Malformed budget files are rejected with a readable error.
   (define bad-path (build-path temp-root "budgets-bad.json"))
   (call-with-output-file bad-path
                          (lambda (out)
                            (displayln "{not json")
                            out))
   (check-exn exn:fail? (lambda () (parse-budget-file bad-path)))
   (call-with-output-file (build-path temp-root "budgets-shape.json")
                          (lambda (out) (write-json (hasheq 'rules "nope") out)))
   (check-exn exn:fail? (lambda () (parse-budget-file (build-path temp-root "budgets-shape.json"))))

   ;; Missing dist: a readable error, not an empty report.
   (check-exn exn:fail? (lambda () (measure-size (build-path temp-root "nowhere"))))

   ;; The budget violation surface: over-budget raises the typed budget exn.
   (check-exn exn:fail:glaze:budget?
              (lambda ()
                (with-handlers ([exn:fail:glaze:budget? (lambda (e) (raise e))])
                  (define report (measure-size temp-root #:budget-path budget-path))
                  (display-size-report report)
                  (unless (null? (hash-ref report 'violations))
                    (raise (exn:fail:glaze:budget "size budgets exceeded"
                                                  (current-continuation-marks)))))))

   ;; launch-survival: a staged executable that sleeps survives its window;
   ;; one that exits immediately fails. Windows CreateProcess launches only
   ;; executable extensions, so the staged scripts get .bat names there and
   ;; sh scripts elsewhere.
   (define script-name (if (eq? (system-type 'os) 'windows) "sleeper.bat" "sleeper"))
   (define (write-script body)
     (define path (build-path dist script-name))
     (call-with-output-file path (lambda (out) (display body out)) #:exists 'replace)
     (file-or-directory-permissions path
                                    (bitwise-ior (file-or-directory-permissions path 'bits)
                                                 user-execute-bit))
     path)
   (define sleeper
     (write-script (if (eq? (system-type 'os) 'windows)
                       "@echo off\r\nping -n 30 127.0.0.1 > nul\r\n"
                       "#!/bin/sh\nsleep 30\n")))
   (define elapsed (launch-survival! sleeper 0.5))
   (check-true (>= elapsed 0.4) "survivor reports its window")

   (define quitter
     (write-script
      (if (eq? (system-type 'os) 'windows) "@echo off\r\nexit /b 0\r\n" "#!/bin/sh\nexit 0\n")))
   (check-exn exn:fail?
              (lambda () (launch-survival! quitter 0.5))
              "an artifact that exits early fails its survival window"))
 (lambda () (delete-directory/files temp-root)))
