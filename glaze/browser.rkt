#lang racket/base

(require racket/system)

(provide open-browser)

;; Open a URL without invoking a command shell. The old implementation built a
;; shell command with `format`, so an untrusted URL containing shell
;; metacharacters could execute arbitrary commands in the app's user context.
(define (open-browser url)
  (unless (string? url)
    (raise-argument-error 'open-browser "string?" url))
  (define-values (exe args)
    (case (system-type 'os)
      [(windows)
       ;; rundll32's FileProtocolHandler delegates to the registered default
       ;; handler. system* keeps the URL as a single argv element.
       (values (find-executable-path "rundll32.exe" #f)
               (list "url.dll,FileProtocolHandler" url))]
      [(macosx)
       (values (find-executable-path "open" #f) (list url))]
      [(unix)
       (values (find-executable-path "xdg-open" #f) (list url))]
      [else (values #f '())]))
  (and exe (apply system* exe args)))
