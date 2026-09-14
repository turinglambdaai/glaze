#lang racket/base

(require racket/match
         racket/system)

(provide open-browser)

(define (open-browser url)
  (define cmd
    (match (system-type 'os)
      ['windows (format "start ~a" url)]
      ['macosx (format "open ~a" url)]
      ['unix (format "xdg-open ~a" url)]
      [_ #f]))
  (when cmd
    (system cmd)))
