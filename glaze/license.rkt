#lang racket/base

;; Offline license keys for paid Glaze apps. A license is a JSON file with
;; app-defined claims (product, subject, optional expiry and machine
;; binding) plus an RSA-2048 / SHA-256 signature. Verification shells out to
;; the system `openssl` CLI (present on macOS and Linux out of the box; Git
;; for Windows ships it too), so glaze keeps its zero-native-dependency
;; property — no crypto package, no C compiler.
;;
;; Workflow for an app vendor:
;;
;;   1. raco glaze keygen --out keys          ; once; ship public.pem, keep private.pem
;;   2. raco glaze license sign --key keys/private.pem
;;             --product "MyApp" --subject "customer@example.com"
;;             [--expiry 2027-12-31] [--machine-id <id>] --out app.license
;;   3. in the app:
;;      (require glaze/license)
;;      (define r (validate-license "app.license"
;;                                  #:public-key "public.pem"
;;                                  #:product "MyApp"))
;;      (hash-ref r 'valid)  ; #t / #f, with 'reason on failure
;;
;; File format: claims as JSON plus a base64 "signature" field. The
;; signature covers the canonical JSON of all fields EXCEPT "signature"
;; (keys sorted, deterministic string escaping — see canonical-json), so the
;; on-disk file can be re-formatted without breaking verification.
;;
;; Machine binding: (machine-id) returns a stable per-machine digest of the
;; OS machine identifier — IOPlatformUUID (macOS), /etc/machine-id (Linux),
;; MachineGuid (Windows), username+hostname fallback. The raw OS identifier
;; never leaves this function. Binding is a courtesy check: a local attacker
;; can always patch the app, so no claim of tamper resistance is made.

(require json
         net/base64
         racket/date
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string
         racket/system)

(provide machine-id
         issue-license
         validate-license
         license-valid?
         days-until-expiry)

;; ---- openssl subprocess plumbing ----

(define (openssl-path)
  (find-executable-path "openssl" #f))

;; Run the openssl CLI with `args`; returns the exit code, or #f when the
;; executable is missing or the process could not be spawned.
(define (openssl-exit-code . args)
  (define exe (openssl-path))
  (and exe
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (apply system*/exit-code exe args))))

;; ---- hashing ----

;; SHA-256 hex digest of `data` bytes via `openssl dgst -r` (stable
;; "<hex> *<file>" output across OpenSSL and LibreSSL). #f when openssl is
;; missing.
(define (sha256-hex data)
  (define dir (make-temporary-file "glaze-sha-~a" 'directory))
  (define f (build-path dir "data.bin"))
  (call-with-output-file f (lambda (out) (write-bytes data out)) #:exists 'replace)
  (begin0
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (define out (open-output-string))
      (parameterize ([current-output-port out])
        (openssl-exit-code "dgst" "-sha256" "-r" (path->string f)))
      ;; #px, not #rx: the {64} quantifier needs Perl-style syntax
      (define m (regexp-match #px"^([0-9a-fA-F]{64})\\b" (get-output-string out)))
      (and m (string-downcase (second m))))
    (delete-directory/files dir)))

;; ---- machine identifier ----

;; Stable per-machine identifier: SHA-256 hex over the platform's raw
;; machine identifier, with a username+hostname fallback.
(define (machine-id)
  (define raw
    (or (case (system-type 'os)
          [(macosx) (raw-macos-uuid)]
          [(windows) (raw-windows-guid)]
          [else (raw-linux-machine-id)])
        (raw-fallback)))
  (sha256-hex (string->bytes/utf-8 raw)))

(define (raw-macos-uuid)
  (define exe (find-executable-path "ioreg" #f))
  (and exe
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (define out (open-output-string))
         (parameterize ([current-output-port out])
           (system*/exit-code exe "-rd1" "-c" "IOPlatformExpertDevice"))
         (define m (regexp-match #rx"\"IOPlatformUUID\"\\s*=\\s*\"([^\"]+)\""
                                 (get-output-string out)))
         (and m (second m)))))

(define (raw-windows-guid)
  (define exe (find-executable-path "reg.exe" #f))
  (and exe
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (define out (open-output-string))
         (parameterize ([current-output-port out])
           (system*/exit-code exe
                              "query"
                              "HKLM\\SOFTWARE\\Microsoft\\Cryptography"
                              "/v" "MachineGuid"))
         (define m (regexp-match #rx"REG_SZ\\s+(\\S+)" (get-output-string out)))
         (and m (second m)))))

(define (raw-linux-machine-id)
  (or (and (file-exists? "/etc/machine-id")
           (string-trim (file->string "/etc/machine-id")))
      (and (file-exists? "/var/lib/dbus/machine-id")
           (string-trim (file->string "/var/lib/dbus/machine-id")))))

(define (raw-fallback)
  (format "~a|~a"
          (or (getenv "USERNAME") (getenv "USER") "user")
          (or (getenv "COMPUTERNAME") (getenv "HOSTNAME") "host")))

;; ---- canonical JSON ----

;; Deterministic JSON for jsexpr claims: object keys sorted, JSON-standard
;; string escaping, no whitespace. Issuing and verifying both sign/verify
;; these exact bytes; the on-disk file itself may be formatted freely.
(define (canonical-json v)
  (string->bytes/utf-8 (json-fragment v)))

(define (json-fragment v)
  (cond
    [(hash? v)
     (string-append
      "{"
      (string-join
       (for/list ([k (in-list (sort (hash-keys v) string<? #:key symbol->string))])
         (format "~a:~a"
                 (json-string (symbol->string k))
                 (json-fragment (hash-ref v k))))
       ",")
      "}")]
    [(list? v)
     (string-append "[" (string-join (map json-fragment v) ",") "]")]
    [(string? v) (json-string v)]
    [(real? v) (~a v)]
    [(boolean? v) (if v "true" "false")]
    [else (json-string (format "~a" v))]))

(define (json-string s)
  ;; Let the JSON library handle every required escape (including control
  ;; characters below U+0020) instead of maintaining a partial encoder.
  (jsexpr->string s))


;; ---- RSA-SHA256 over payload bytes ----

;; Sign `payload` with a PEM private key; returns the raw signature bytes or
;; #f on any failure (openssl missing, unreadable key, ...).
(define (sign-payload payload private-key-path)
  (define dir (make-temporary-file "glaze-license-~a" 'directory))
  (define payload-path (build-path dir "payload.bin"))
  (define sig-path (build-path dir "sig.bin"))
  (call-with-output-file payload-path
                         (lambda (out) (write-bytes payload out))
                         #:exists 'replace)
  (begin0
    (let ([code (openssl-exit-code "dgst" "-sha256" "-sign"
                                   (path->string (path->complete-path private-key-path))
                                   "-out" (path->string sig-path)
                                   (path->string payload-path))])
      (and code (zero? code) (file-exists? sig-path)
           (file->bytes sig-path)))
    (delete-directory/files dir)))

;; Verify an RSA-SHA256 signature (base64 string) over `payload` with a PEM
;; public key. #f on any failure.
(define (verify-payload payload signature-b64 public-key-path)
  (define sig
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (base64-decode (string->bytes/utf-8 signature-b64))))
  (and sig
       (let ([dir (make-temporary-file "glaze-license-~a" 'directory)])
         (define payload-path (build-path dir "payload.bin"))
         (define sig-path (build-path dir "sig.bin"))
         (call-with-output-file payload-path
                                (lambda (out) (write-bytes payload out))
                                #:exists 'replace)
         (call-with-output-file sig-path
                                (lambda (out) (write-bytes sig out))
                                #:exists 'replace)
         (begin0
           (let ([code (openssl-exit-code "dgst" "-sha256" "-verify"
                                          (path->string (path->complete-path public-key-path))
                                          "-signature" (path->string sig-path)
                                          (path->string payload-path))])
             (and code (zero? code)))
           (delete-directory/files dir)))))

;; ---- issuing ----

;; Issue (sign) a license file.
;;
;;   (issue-license #:private-key "keys/private.pem"
;;                  #:product "MyApp" #:subject "customer@example.com"
;;                  #:expiry "2027-12-31"            ; optional
;;                  #:machine-id (machine-id)        ; optional
;;                  #:out "app.license")
;; Returns the output path. Raises on signing failure.
(define (issue-license #:private-key private-key
                       #:product product
                       #:subject subject
                       #:expiry [expiry #f]
                       #:machine-id [machine #f]
                       #:out [out "app.license"])
  (unless (path-string? private-key)
    (raise-argument-error 'issue-license "path-string?" private-key))
  (unless (and (string? product) (non-empty-string? product))
    (raise-argument-error 'issue-license "non-empty-string?" product))
  (unless (and (string? subject) (non-empty-string? subject))
    (raise-argument-error 'issue-license "non-empty-string?" subject))
  (when expiry
    (unless (string? expiry)
      (raise-argument-error 'issue-license "(or/c #f string?)" expiry))
    ;; Parse now so malformed dates cannot be signed into a license that every
    ;; validator will later reject or interpret inconsistently.
    (days-until-expiry expiry))
  (when (and machine (not (string? machine)))
    (raise-argument-error 'issue-license "(or/c #f string?)" machine))
  (unless (path-string? out)
    (raise-argument-error 'issue-license "path-string?" out))
  (define claims
    (make-hasheq
     (append (list (cons 'product product)
                   (cons 'subject subject))
             (if expiry (list (cons 'expiry expiry)) '())
             (if machine (list (cons 'machine-id machine)) '()))))
  (define sig (sign-payload (canonical-json claims) private-key))
  (unless sig
    (error 'issue-license "signing failed (openssl missing or key unreadable)"))
  (hash-set! claims 'signature
             (string-trim (bytes->string/utf-8 (base64-encode sig #""))))
  (define out-path (if (path? out) out (string->path out)))
  (call-with-output-file out-path
                         (lambda (o) (write-json claims o))
                         #:exists 'replace)
  out-path)

;; ---- validation ----

;; Validate a license file:
;;
;;   (validate-license "app.license" #:public-key "public.pem" #:product "MyApp"
;;                     #:machine-id (machine-id))   ; optional binding check
;;
;; Returns a hash. Success: {'valid #t, 'subject s, 'expiry e-or-#f,
;; 'machine-id m-or-#f}. Failure: {'valid #f, 'reason tag} with tag one of
;; "missing-file" / "malformed" / "signature" / "product" / "expired" /
;; "machine" / "openssl-unavailable".
(define (validate-license license-file
                          #:public-key public-key
                          #:product product
                          #:machine-id [machine (machine-id)])
  (let/ec return
    (define (fail reason) (return (hasheq 'valid #f 'reason reason)))
    (unless (file-exists? license-file)
      (fail "missing-file"))
    (unless (openssl-path)
      (fail "openssl-unavailable"))
    (define data
      (with-handlers ([exn:fail? (lambda (e) #f)])
        (call-with-input-file license-file read-json)))
    (unless (hash? data)
      (fail "malformed"))
    (define sig (hash-ref data 'signature #f))
    (unless (string? sig)
      (fail "malformed"))
    (define claims
      (for/hasheq ([(k v) (in-hash data)]
                   #:unless (eq? k 'signature))
        (values k v)))
    (unless (verify-payload (canonical-json claims) sig public-key)
      (fail "signature"))
    (unless (equal? (hash-ref claims 'product #f) product)
      (fail "product"))
    (define expiry (hash-ref claims 'expiry #f))
    (when (and expiry (not (string? expiry)))
      (fail "malformed"))
    (when (and expiry (date-passed? expiry))
      (fail "expired"))
    (define bound (hash-ref claims 'machine-id #f))
    (when (and bound (not (equal? bound machine)))
      (fail "machine"))
    (hasheq 'valid #t
            'subject (hash-ref claims 'subject #f)
            'expiry (or expiry #f)
            'machine-id (or bound #f))))

;; Boolean convenience wrapper.
(define (license-valid? license-file #:public-key public-key
                        #:product product
                        #:machine-id [machine (machine-id)])
  (hash-ref (validate-license license-file
                              #:public-key public-key
                              #:product product
                              #:machine-id machine)
            'valid))

;; Days until an "YYYY-MM-DD" expiry (expiry day inclusive); negative when
;; already past. Raises on a malformed date.
(define (days-until-expiry expiry)
  (unless (string? expiry)
    (raise-argument-error 'days-until-expiry "string?" expiry))
  ;; #px, not #rx: {n} quantifiers need Perl-style syntax.
  (define m (regexp-match #px"^([0-9]{4})-([0-9]{2})-([0-9]{2})$" expiry))
  (unless m (error 'days-until-expiry "malformed expiry date: ~a" expiry))
  (define y (string->number (second m)))
  (define mo (string->number (third m)))
  (define d (string->number (fourth m)))
  (define secs-exp
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (error 'days-until-expiry
                              "invalid expiry date: ~a" expiry))])
      ;; Use UTC so daylight-saving transitions cannot turn a calendar day
      ;; into 23/25 hours and shift the result by one.
      (find-seconds 0 0 0 d mo y #f)))
  (define parsed (seconds->date secs-exp #f))
  (unless (and (= (date-year parsed) y)
               (= (date-month parsed) mo)
               (= (date-day parsed) d))
    (error 'days-until-expiry "invalid expiry date: ~a" expiry))
  (define today (current-date))
  (define secs-now
    (find-seconds 0 0 0
                  (date-day today) (date-month today)
                  (date-year today) #f))
  (quotient (- secs-exp secs-now) 86400))

;; True when the YYYY-MM-DD date is strictly before today.
(define (date-passed? ymd)
  (< (days-until-expiry ymd) 0))
