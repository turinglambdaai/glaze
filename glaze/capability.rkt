#lang racket/base

;; Runtime authority for the WebView -> Racket bridge.  A capability grants
;; named permissions; scoped permissions additionally inspect the resource a
;; route wants to use.  The server enables this model explicitly, preserving
;; the open-route behavior of existing Glaze applications.

(require racket/list
         racket/path
         racket/string)

(provide capability?
         capability-id
         make-capability
         allow-permission
         scoped-permission
         path-permission
         command-permission
         command-resource
         command-resource?
         command-resource-program
         command-resource-arguments
         capability-has-permission?
         capability-authorized?
         current-capability-id)

(struct capability (id grants) #:transparent)
(struct permission-grant (id authorize) #:transparent)
(struct command-resource (program arguments) #:transparent)

(define current-capability-id (make-parameter #f))

(define (permission-id who id)
  (cond
    [(symbol? id) id]
    [(and (string? id) (not (string=? id ""))) (string->symbol id)]
    [else (raise-argument-error who "(or/c symbol? non-empty-string?)" id)]))

(define (allow-permission id)
  (permission-grant (permission-id 'allow-permission id) (lambda (resource) #t)))

(define (scoped-permission id authorize)
  (unless (procedure? authorize)
    (raise-argument-error 'scoped-permission "procedure?" authorize))
  (permission-grant (permission-id 'scoped-permission id) authorize))

(define (make-capability id permissions)
  (unless (and (string? id) (not (string=? id "")))
    (raise-argument-error 'make-capability "non-empty-string?" id))
  (unless (list? permissions)
    (raise-argument-error 'make-capability "list?" permissions))
  (define grants
    (for/list ([permission (in-list permissions)])
      (cond
        [(permission-grant? permission) permission]
        [(or (symbol? permission) (string? permission)) (allow-permission permission)]
        [else
         (raise-argument-error 'make-capability
                               "list of permission identifiers or scoped permissions"
                               permissions)])))
  (define duplicate (check-duplicates (map permission-grant-id grants) eq?))
  (when duplicate
    (raise-arguments-error 'make-capability
                           "duplicate permission identifiers are ambiguous"
                           "permission"
                           duplicate))
  (capability id grants))

(define (capability-has-permission? cap id)
  (unless (capability? cap)
    (raise-argument-error 'capability-has-permission? "capability?" cap))
  (define wanted (permission-id 'capability-has-permission? id))
  (for/or ([grant (in-list (capability-grants cap))])
    (eq? wanted (permission-grant-id grant))))

(define (capability-authorized? cap id [resource #f])
  (unless (capability? cap)
    (raise-argument-error 'capability-authorized? "capability?" cap))
  (define wanted (permission-id 'capability-authorized? id))
  (for/or ([grant (in-list (capability-grants cap))]
           #:when (eq? wanted (permission-grant-id grant)))
    (and ((permission-grant-authorize grant) resource) #t)))

;; Resolve every existing symlink component before checking containment.  A
;; single resolve-path on the leaf is insufficient: root/link/new-file has a
;; non-existent leaf, and `link` may still point outside root.
(define (canonical-path p)
  (unless (path-string? p)
    (raise-argument-error 'path-permission "path-string? resource" p))
  (define (resolve-components path seen)
    (define lexical (simplify-path (path->complete-path path) #f))
    (define parts (explode-path lexical))
    (for/fold ([resolved (car parts)]) ([part (in-list (cdr parts))])
      (define candidate (build-path resolved part))
      (define kind (file-or-directory-type candidate #f))
      (cond
        [(memq kind '(link directory-link))
         (define key (path->string candidate))
         (when (member key seen)
           (raise-arguments-error 'path-permission "cyclic symbolic link" "path" p))
         ;; resolve-path may return the link target as a relative path on Unix;
         ;; interpret it relative to the directory that owns the link.
         (define target (resolve-path candidate))
         (define complete-target
           (if (complete-path? target)
               target
               (path->complete-path target (path-only candidate))))
         (resolve-components complete-target (cons key seen))]
        [else candidate])))
  (resolve-components p '()))

(define (path-key p)
  (define normalized (regexp-replace* #rx"\\\\" (path->string (canonical-path p)) "/"))
  (if (eq? (system-type 'os) 'windows)
      (string-downcase normalized)
      normalized))

(define (path-inside? root candidate)
  (define root-key (string-trim (path-key root) "/" #:left? #f))
  (define candidate-key (string-trim (path-key candidate) "/" #:left? #f))
  (or (string=? root-key candidate-key) (string-prefix? candidate-key (string-append root-key "/"))))

(define (path-permission id #:allow allow-roots #:deny [deny-roots '()])
  (unless (and (list? allow-roots) (andmap path-string? allow-roots))
    (raise-argument-error 'path-permission "list of path strings" allow-roots))
  (unless (and (list? deny-roots) (andmap path-string? deny-roots))
    (raise-argument-error 'path-permission "list of path strings" deny-roots))
  (define allowed (map canonical-path allow-roots))
  (define denied (map canonical-path deny-roots))
  (scoped-permission
   id
   (lambda (resource)
     (define resources
       (cond
         [(path-string? resource) (list resource)]
         [(and (list? resource) (pair? resource) (andmap path-string? resource)) resource]
         [else #f]))
     (and resources
          (with-handlers ([exn:fail? (lambda (e) #f)])
            (for/and ([resource-path (in-list resources)])
              (define candidate (canonical-path resource-path))
              (and (for/or ([root (in-list allowed)])
                     (path-inside? root candidate))
                   (not (for/or ([root (in-list denied)])
                          (path-inside? root candidate))))))))))

(define (command-key program)
  (unless (path-string? program)
    (raise-argument-error 'command-permission "path-string? program" program))
  (define s
    (if (path? program)
        (path->string program)
        program))
  (if (eq? (system-type 'os) 'windows)
      (string-downcase s)
      s))

(define (command-permission id
                            #:allow allow-programs
                            #:deny [deny-programs '()]
                            #:arguments [arguments-ok? (lambda (arguments) #t)])
  (unless (and (list? allow-programs) (andmap path-string? allow-programs))
    (raise-argument-error 'command-permission "list of path strings" allow-programs))
  (unless (and (list? deny-programs) (andmap path-string? deny-programs))
    (raise-argument-error 'command-permission "list of path strings" deny-programs))
  (unless (procedure? arguments-ok?)
    (raise-argument-error 'command-permission "procedure?" arguments-ok?))
  (define allowed (map command-key allow-programs))
  (define denied (map command-key deny-programs))
  (scoped-permission id
                     (lambda (resource)
                       (and (command-resource? resource)
                            (list? (command-resource-arguments resource))
                            (path-string? (command-resource-program resource))
                            (with-handlers ([exn:fail? (lambda (e) #f)])
                              (let ([program (command-key (command-resource-program resource))]
                                    [arguments (command-resource-arguments resource)])
                                (and (member program allowed)
                                     (not (member program denied))
                                     (arguments-ok? arguments))))))))
