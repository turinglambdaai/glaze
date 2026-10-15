#lang racket/base

;; Direct contract for the resource boundary shared by native platform hosts.

(require racket/file
         racket/path
         rackunit
         glaze/private/native-resources)

(test-case "controlled native origins share one URL parser"
  (check-equal? (native-scheme-segments "glaze://app/assets/app.js?x=1#part")
                '("assets" "app.js"))
  (check-equal? (native-scheme-segments "http://glaze.localhost/assets/a%20b.css")
                '("assets" "a b.css"))
  (check-equal? (native-scheme-segments "https://glaze.localhost/") '())
  (check-false (native-scheme-segments "https://example.test/app.js"))
  (check-not-false (member (native-app-origin)
                           '("glaze://app/" "http://glaze.localhost/"))))

(test-case "resource lookup is contained and keeps SPA fallback semantics"
  (define root (make-temporary-file "glaze-native-resource-~a" 'directory))
  (define outside (make-temporary-file "glaze-native-secret-~a"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file (build-path root "index.html")
        (lambda (out) (display "INDEX" out)))
      (make-directory (build-path root "assets"))
      (call-with-output-file (build-path root "assets" "app.js")
        (lambda (out) (display "APP" out)))
      (define-values (mime bytes) (static-resource root '("assets" "app.js")))
      (check-equal? mime #"application/javascript; charset=utf-8")
      (check-equal? bytes #"APP")
      (define-values (fallback-mime fallback-bytes) (static-resource root '("missing")))
      (check-equal? fallback-mime #"text/html; charset=utf-8")
      (check-equal? fallback-bytes #"INDEX")
      (define-values (escape-mime escape-bytes)
        (static-resource root (list ".." (path->string (file-name-from-path outside)))))
      (check-equal? escape-mime #"text/html; charset=utf-8")
      (check-equal? escape-bytes #"INDEX"))
    (lambda ()
      (delete-directory/files root)
      (delete-file outside))))
