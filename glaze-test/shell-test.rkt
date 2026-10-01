#lang racket/base

(require json
         net/http-client
         racket/file
         racket/port
         racket/string
         rackunit
         glaze/capability
         glaze/server
         glaze/shell)

(define racket-executable (path->string (find-system-path 'exec-file)))
(define (racket-expression expression)
  (list "-e" expression))

;; Direct execution captures stdout/stderr and exit status without a shell.
(define direct-result
  (shell-output racket-executable
                (racket-expression
                 "(begin (display \"out\") (display \"err\" (current-error-port)))")))
(check-equal? (hash-ref direct-result 'status) "exited")
(check-equal? (hash-ref direct-result 'code) 0)
(check-equal? (hash-ref direct-result 'stdout) "out")
(check-equal? (hash-ref direct-result 'stderr) "err")
(check-false (hash-ref direct-result 'timedOut))

(define temp-dir (make-temporary-file "glaze-shell-~a" 'directory))
(define outside-dir (make-temporary-file "glaze-shell-outside-~a" 'directory))
(call-with-output-file (build-path temp-dir "cwd-marker") void)
(define env-result
  (shell-output
   racket-executable
   (racket-expression
    "(begin (display (getenv \"GLAZE_SHELL_TEST\")) (display \"|\") (display (file-exists? \"cwd-marker\")))")
   #:cwd temp-dir
   #:env (hasheq 'GLAZE_SHELL_TEST "environment-ok")))
(check-equal? (hash-ref env-result 'stdout) "environment-ok|#t")

(define timeout-result
  (shell-output racket-executable (racket-expression "(sleep 2)") #:timeout 0.05))
(check-true (hash-ref timeout-result 'timedOut))
(check-equal? (hash-ref timeout-result 'status) "exited")

(define truncated-result
  (shell-output racket-executable
                (racket-expression "(display (make-string 100 #\\x))")
                #:max-output 10))
(check-equal? (hash-ref truncated-result 'stdout) "xxxxxxxxxx")
(check-true (hash-ref truncated-result 'stdoutTruncated))

;; Background handles support stdin, polling, and termination.
(define stdin-child
  (if (eq? (system-type 'os) 'windows)
      (shell-spawn! racket-executable (racket-expression "(display (read-line))"))
      (shell-spawn! "/bin/cat")))
(shell-process-write! stdin-child "hello child\n")
(shell-process-close-input! stdin-child)
(check-true (shell-process-wait stdin-child 5))
(check-equal? (string-trim (hash-ref (shell-process-info stdin-child) 'stdout)) "hello child")

(define killed-child (shell-spawn! racket-executable (racket-expression "(sleep 10)")))
(shell-process-close-input! killed-child)
(shell-process-kill! killed-child)
(check-true (shell-process-wait killed-child 5))
(check-equal? (hash-ref (shell-process-info killed-child) 'status) "exited")

;; HTTP routes apply command/argument scope before process creation and bind
;; background handles to the active capability.
(define authority
  (make-capability "main"
                   (list (command-permission 'shell:execute
                                             #:allow (list racket-executable)
                                             #:arguments (lambda (arguments)
                                                           (and (pair? arguments)
                                                                (string=? (car arguments) "-e"))))
                         'shell:manage)))
(define token "shell-test-token")
(define shell-routes
  (make-shell-routes #:max-output 1024
                     #:cwd-roots (list temp-dir)
                     #:allow-environment '(GLAZE_ROUTE_ENV)))
(define-values (_port shutdown)
  (start-server #:port 18975
                #:public-dir temp-dir
                #:api-token token
                #:capability authority
                #:api shell-routes))

(define (call-at port api-token path body)
  (define-values (status headers in)
    (http-sendrecv "127.0.0.1"
                   path
                   #:port port
                   #:ssl? #f
                   #:method "POST"
                   #:data (string->bytes/utf-8 (jsexpr->string body))
                   #:headers (list "Content-Type: application/json"
                                   (string-append "X-Glaze-Token: " api-token))))
  (define response-bytes (port->bytes in))
  (close-input-port in)
  (values (bytes->string/utf-8 status)
          (and (positive? (bytes-length response-bytes)) (bytes->jsexpr response-bytes))))

(define (call path body)
  (call-at 18975 token path body))

(let-values ([(status body) (call "/api/shell/output"
                                  (hasheq 'program
                                          racket-executable
                                          'arguments
                                          (racket-expression "(display \"route output\")")))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref body 'stdout) "route output")
  (check-equal? (hash-ref body 'code) 0))

(let-values
    ([(status body)
      (call
       "/api/shell/output"
       (hasheq
        'program
        racket-executable
        'arguments
        (racket-expression
         "(begin (display (getenv \"GLAZE_ROUTE_ENV\")) (display \"|\") (display (file-exists? \"cwd-marker\")))")
        'cwd
        (path->string temp-dir)
        'env
        (hasheq 'GLAZE_ROUTE_ENV "route-env")))])
  (check-true (string-contains? status "200"))
  (check-equal? (hash-ref body 'stdout) "route-env|#t"))

(let-values ([(status body) (call "/api/shell/output"
                                  (hasheq 'program
                                          racket-executable
                                          'arguments
                                          (racket-expression "(void)")
                                          'cwd
                                          (path->string outside-dir)))])
  (check-true (string-contains? status "400")))

(let-values ([(status body) (call "/api/shell/output"
                                  (hasheq 'program
                                          racket-executable
                                          'arguments
                                          (racket-expression "(void)")
                                          'env
                                          (hasheq 'LD_PRELOAD "blocked")))])
  (check-true (string-contains? status "400")))

(let-values ([(status body)
              (call "/api/shell/output"
                    (hasheq 'program "definitely-not-allowed" 'arguments '("-e" "(void)")))])
  (check-true (string-contains? status "403")))

(define route-id
  (let-values ([(status body) (call "/api/shell/spawn"
                                    (hasheq 'program
                                            racket-executable
                                            'arguments
                                            (racket-expression "(display (read-line))")))])
    (check-true (string-contains? status "200"))
    (hash-ref body 'id)))

(let-values ([(status body) (call "/api/shell/write" (hasheq 'id route-id 'data "route stdin\n"))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref body 'ok)))
(let-values ([(status body) (call "/api/shell/close-stdin" (hasheq 'id route-id))])
  (check-true (string-contains? status "200")))

(define route-info
  (let loop ([attempts 50])
    (let-values ([(status body) (call "/api/shell/status" (hasheq 'id route-id))])
      (check-true (string-contains? status "200"))
      (cond
        [(string=? (hash-ref body 'status) "exited") body]
        [(zero? attempts) body]
        [else
         (sleep 0.05)
         (loop (sub1 attempts))]))))
(check-equal? (hash-ref route-info 'status) "exited")
(check-equal? (hash-ref route-info 'stdout) "route stdin")

(define secondary-token "shell-secondary-token")
(define-values (_secondary-port shutdown-secondary)
  (start-server #:port 18976
                #:public-dir temp-dir
                #:api-token secondary-token
                #:capability (make-capability "secondary" '(shell:manage))
                #:api shell-routes))
(let-values ([(status body)
              (call-at 18976 secondary-token "/api/shell/status" (hasheq 'id route-id))])
  (check-true (string-contains? status "400")))
(shutdown-secondary)

(define kill-id
  (let-values ([(status body)
                (call
                 "/api/shell/spawn"
                 (hasheq 'program racket-executable 'arguments (racket-expression "(sleep 10)")))])
    (check-true (string-contains? status "200"))
    (hash-ref body 'id)))
(let-values ([(status body) (call "/api/shell/kill" (hasheq 'id kill-id 'force #t))])
  (check-true (string-contains? status "200"))
  (check-true (hash-ref body 'ok)))

(shutdown)
(delete-directory/files temp-dir)
(delete-directory/files outside-dir)
