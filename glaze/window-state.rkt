#lang racket/base

(require json
         racket/file
         racket/math
         racket/path
         racket/string)

(provide (struct-out window-state)
         (struct-out screen-area)
         default-window-state-path
         read-window-state
         write-window-state!
         normalize-window-state)

(struct window-state (x y width height maximized?) #:transparent)
(struct screen-area (x y width height) #:transparent)

(define (safe-component value)
  (define cleaned (regexp-replace* #px"[^0-9A-Za-z._-]+" (format "~a" value) "-"))
  (if (non-empty-string? cleaned) cleaned "app"))

(define (default-window-state-path app-id)
  (build-path (find-system-path 'pref-dir) "glaze" (safe-component app-id) "window-state.json"))

(define (finite-real? value)
  (and (real? value) (not (infinite? value)) (not (nan? value))))

(define (positive-size? value)
  (and (finite-real? value) (> value 0)))

(define (jsexpr->window-state value)
  (and (hash? value)
       (let ([x (hash-ref value 'x #f)]
             [y (hash-ref value 'y #f)]
             [width (hash-ref value 'width #f)]
             [height (hash-ref value 'height #f)]
             [maximized? (hash-ref value 'maximized #f)])
         (and (finite-real? x)
              (finite-real? y)
              (positive-size? width)
              (positive-size? height)
              (boolean? maximized?)
              (window-state x y width height maximized?)))))

(define (read-window-state path)
  (and path
       (file-exists? path)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (call-with-input-file path (lambda (input) (jsexpr->window-state (read-json input)))))))

(define (write-window-state! path state)
  (unless (window-state? state)
    (raise-argument-error 'write-window-state! "window-state?" state))
  (make-parent-directory* path)
  (call-with-atomic-output-file path
                                (lambda (output temporary-path)
                                  (write-json (hasheq 'x
                                                      (window-state-x state)
                                                      'y
                                                      (window-state-y state)
                                                      'width
                                                      (window-state-width state)
                                                      'height
                                                      (window-state-height state)
                                                      'maximized
                                                      (window-state-maximized? state))
                                              output)
                                  (newline output)))
  path)

(define (clamp value minimum maximum)
  (min maximum (max minimum value)))

;; Keep the complete restored frame inside the current virtual desktop. If a
;; saved window is larger than the current desktop (for example after a DPI or
;; monitor change), shrink it first. This is the stranded-window guard.
(define (normalize-window-state state area)
  (unless (window-state? state)
    (raise-argument-error 'normalize-window-state "window-state?" state))
  (unless (screen-area? area)
    (raise-argument-error 'normalize-window-state "screen-area?" area))
  (define width (min (window-state-width state) (screen-area-width area)))
  (define height (min (window-state-height state) (screen-area-height area)))
  (define minimum-x (screen-area-x area))
  (define minimum-y (screen-area-y area))
  (define maximum-x (+ minimum-x (- (screen-area-width area) width)))
  (define maximum-y (+ minimum-y (- (screen-area-height area) height)))
  (window-state (clamp (window-state-x state) minimum-x maximum-x)
                (clamp (window-state-y state) minimum-y maximum-y)
                width
                height
                (window-state-maximized? state)))
