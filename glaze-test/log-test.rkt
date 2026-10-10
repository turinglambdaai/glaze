#lang racket/base

(require json
         net/http-client
         net/uri-codec
         racket/file
         racket/list
         racket/port
         racket/string
         rackunit
         glaze/capability
         glaze/events
         glaze/log
         glaze/server)

;; ---- levels ----

(check-true (log-level? 'trace))
(check-true (log-level? 'error))
(check-false (log-level? 'fatal))
(check-exn exn:fail? (lambda () (make-glaze-logger #:min-level 'loud)))

;; ---- filtering, history, sinks ----

(define quiet (make-glaze-logger #:min-level 'info #:history 3))
(log-trace quiet "dropped")
(log-debug quiet "dropped too")
(check-equal? (length (glaze-logger-history quiet)) 0 "records below min-level are dropped")
(log-info quiet "kept")
(log-warn quiet "kept" #:data (hasheq 'code 7))
(log-error quiet "kept")
(check-equal? (map log-record-message (glaze-logger-history quiet)) (list "kept" "kept" "kept"))
(check-equal? (log-record-level (third (glaze-logger-history quiet))) 'error)
(check-equal? (log-record-data (second (glaze-logger-history quiet))) (hasheq 'code 7))
(check-false (log-record-capability (first (glaze-logger-history quiet)))
             "backend records outside routes carry no capability")

;; ring bound: the 4th record drops the oldest
(log-info quiet "fourth")
(check-equal? (map log-record-message (glaze-logger-history quiet)) (list "kept" "kept" "fourth"))
(log-info quiet "fifth")
(check-equal? (map log-record-message (glaze-logger-history quiet)) (list "kept" "fourth" "fifth"))

;; history limit parameter
(check-equal? (length (glaze-logger-history quiet 2)) 2)
(check-equal? (map log-record-message (glaze-logger-history quiet 1)) (list "fifth"))

;; per-sink minimum levels
(define received '())
(define tap (lambda (r) (set! received (append received (list r)))))
(define loud (make-glaze-logger #:min-level 'trace #:sinks (list (log-sink 'error tap))))
(log-info loud "not seen by sink")
(check-equal? received '() "sink filters below its own level")
(log-error loud "seen")
(check-equal? (map log-record-message received) (list "seen"))
;; plain procedures are accepted as trace-level sinks
(define tapped-any '())
(define loud2
  (make-glaze-logger #:min-level 'trace
                     #:sinks (list (lambda (r) (set! tapped-any (append tapped-any (list r)))))))
(log-trace loud2 "raw sink sees everything")
(check-equal? (map log-record-message tapped-any) (list "raw sink sees everything"))

;; validation
(check-exn exn:fail? (lambda () (log-info quiet "")) "empty messages are rejected")
(check-exn exn:fail?
           (lambda () (log-info quiet "msg" #:data (vector 1 2)))
           "non-jsexpr data is rejected")

;; ---- file sink and rotation ----

(define log-dir (make-temporary-file "glaze-log-~a" 'directory))
(define rotating (make-file-log-sink log-dir #:max-bytes 120 #:keep 2))
(for ([n (in-range 40)])
  (rotating
   (log-record "2026-10-09T00:00:00.000" 'info (format "message ~a padding" n) 'backend #f #f)))
(check-true (file-exists? (build-path log-dir "glaze.log")))
(check-true (file-exists? (build-path log-dir "glaze.log.1")))
(check-true (file-exists? (build-path log-dir "glaze.log.2")))
(check-false (file-exists? (build-path log-dir "glaze.log.3"))
             "keep=2 retains exactly two rotated files")
(for ([f (in-list '("glaze.log" "glaze.log.1" "glaze.log.2"))])
  (check-true (<= (file-size (build-path log-dir f)) 130) (format "~a respects the size cap" f)))
(check-true (string-contains? (file->string (build-path log-dir "glaze.log.2")) "INFO [backend]")
            "rotated files keep the line format")

;; keep=0 replaces instead of rotating
(define noreplace-dir (make-temporary-file "glaze-log-keep0-~a" 'directory))
(define noreplace (make-file-log-sink noreplace-dir #:max-bytes 60 #:keep 0))
(noreplace (log-record "t" 'info "first long line of content" 'backend #f #f))
(noreplace (log-record "t" 'info "second long line of content" 'backend #f #f))
(check-false (file-exists? (build-path noreplace-dir "glaze.log.1")))
(check-true (string-contains? (file->string (build-path noreplace-dir "glaze.log")) "second"))

;; ---- SSE push ----

(define bus (make-event-bus))
(define bus-ch (bus-subscribe! bus))
(define pushed (make-glaze-logger #:min-level 'info #:events bus))
(log-warn pushed "push me")
(define event (bus-wait bus-ch 5))
(check-not-eq? event 'timeout "records above min-level push to the bus")
(check-equal? (second event) 'log)
(check-equal? (hash-ref (third event) 'message) "push me")
(check-equal? (hash-ref (third event) 'level) "warn")

;; ---- routes ----

(define root (make-temporary-file "glaze-log-routes-~a" 'directory))
(define authority (make-capability "main" (list 'log:write 'log:read 'glaze:events)))
(define token "log-token")
(define port 18984)
(define logger (make-glaze-logger #:min-level 'info #:history 10))
(define-values (_port shutdown)
  (start-server #:port port
                #:public-dir root
                #:api-token token
                #:capability authority
                #:events bus
                #:api (make-log-routes logger)))

(define (call method path [body #f] #:token? [token? #t])
  (define data (and body (string->bytes/utf-8 (jsexpr->string body))))
  (define-values (status headers in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port port
                   #:ssl? #f
                   #:method method
                   #:data data
                   #:headers (append (if data
                                         '("Content-Type: application/json")
                                         '())
                                     (if token?
                                         (list (string-append "X-Glaze-Token: " token))
                                         '()))))
  (define response-bytes (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status) response-bytes))

(let-values ([(status body)
              (call "POST" "/api/log/write" (hasheq 'level "loud" 'message "bad level"))])
  ;; unknown levels — as symbols or JSON strings — are a client error
  (check-true (string-contains? status "400") "unknown levels are a client error"))
(let-values ([(status body)
              (call "POST" "/api/log/write" (hasheq 'level "warn" 'message "from the page"))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref (bytes->jsexpr body) 'ok)))
(let-values ([(_status body) (call "GET" "/api/log/history")])
  (define records (hash-ref (bytes->jsexpr body) 'records))
  (check-true (pair? records))
  (define r (last records))
  (check-equal? (hash-ref r 'message) "from the page")
  (check-equal? (hash-ref r 'source) "frontend")
  (check-equal? (hash-ref r 'capability) "main")
  (check-equal? (hash-ref r 'level) "warn"))

;; below min-level writes succeed but are filtered like backend records
(let-values ([(_s _b) (call "POST" "/api/log/write" (hasheq 'level "debug" 'message "quiet"))])
  (void))
(check-false (for/or ([r (glaze-logger-history logger)])
               (equal? (log-record-message r) "quiet"))
             "frontend records below min-level are dropped")

;; history limit query
(let-values ([(_status body)
              (call "GET" (string-append "/api/log/history?limit=" (form-urlencoded-encode "1")))])
  (check-equal? (length (hash-ref (bytes->jsexpr body) 'records)) 1))
(let-values ([(status _body) (call "GET" "/api/log/history?limit=9999")])
  (check-true (string-contains? status "400") "out-of-range limits are rejected"))

;; permission and token enforcement
(let-values ([(status _b)
              (call "POST" "/api/log/write" (hasheq 'level "info" 'message "x") #:token? #f)])
  (check-true (string-contains? status "401")))

;; generated client
(let-values ([(_status body) (call "GET" "/glaze/api.js" #f #:token? #f)])
  (define js (bytes->string/utf-8 body))
  (check-true (string-contains? js "logWrite"))
  (check-true (string-contains? js "logHistory")))

(shutdown)

;; a capability without log permissions hides the routes from the client
(define authority-quiet (make-capability "quiet" (list 'os:read)))
(define-values (_p2 shutdown2)
  (start-server #:port 18985
                #:public-dir root
                #:api-token token
                #:capability authority-quiet
                #:api (make-log-routes logger)))
(let-values ([(status headers in) (http-sendrecv "127.0.0.1" "/glaze/api.js" #:port 18985 #:ssl? #f)])
  (define js (bytes->string/utf-8 (port->bytes in)))
  (close-input-port in)
  (check-false (string-contains? js "logWrite") "unauthorized routes are hidden"))
(let-values ([(status headers in) (http-sendrecv "127.0.0.1"
                                                 "/api/log/history"
                                                 #:port 18985
                                                 #:ssl? #f
                                                 #:method "POST"
                                                 #:data #"{}"
                                                 #:headers (list "Content-Type: application/json"
                                                                 (string-append "X-Glaze-Token: "
                                                                                token)))])
  ;; POST against the GET route with the right token but no permission
  (define status-line (bytes->string/utf-8 status))
  (check-false (string-contains? status-line "200") "no silent access without permission")
  (close-input-port in))
(shutdown2)

(delete-directory/files root)
(delete-directory/files log-dir)
(delete-directory/files noreplace-dir)
