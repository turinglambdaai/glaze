#lang racket/base

;; macOS tray backend using Racket's ffi/unsafe/objc (no compiler required).
;;
;; Strategy (mirrors the defn.io "Remember" project's ObjC-FFI pattern):
;;   - Get NSStatusBar's systemStatusBar, create an NSStatusItem.
;;   - Hold a strong reference to the status item via the tray handle (otherwise
;;     ARC reclaims it and the icon vanishes instantly — the classic
;;     NSStatusItem pitfall).
;;   - Build an NSMenu from the menu items. Each NSMenuItem's target/action
;;     points at a singleton ObjC subclass whose glazeAction: method dispatches
;;     to the Racket callback stored in an id->procedure hash keyed by the
;;     item's tag (set via setTag:).
;;   - The icon is set via NSImage initWithContentsOfFile:; tooltip via
;;     setToolTip:.
;;
;; IMPORTANT: this module requires ffi/unsafe/objc which only exists on macOS,
;; so it is only ever loaded on 'macosx via dynamic-require. Requiring it on
;; Windows/Linux would fail at module load. CI on macOS exercises it.

(require ffi/unsafe
         ffi/unsafe/objc
         racket/path
         "tray-protocol.rkt")

(provide make-tray
         set-tooltip!
         set-icon!
         set-menu!
         close
         supported?
         mac:tray?)

(import-class NSString NSStatusBar NSStatusItem NSMenu NSMenuItem NSImage NSObject)

;; AppKit length constants. NSSquareStatusItemLength = -1.0,
;; NSVariableStatusItemLength = -2.0.
(define NSSquareStatusItemLength -1.0)

;; NSSize struct: two CGFloats (width, height). Defined here for setSize:.
;; make-NSSize is the generated constructor.
(define-cstruct _NSSize ([width _double] [height _double]))

;; tag -> action-procedure registry so the ObjC action callback can find the
;; right Racket thunk without crossing into FFI per item.
(define tag-table (make-hash))
(define tag-sema (make-semaphore 1))
(define next-tag (box 1))

(define (alloc-tag!)
  (call-with-semaphore tag-sema
                       (lambda ()
                         (begin0 (unbox next-tag)
                           (set-box! next-tag (add1 (unbox next-tag)))))))
(define (tag-put! tag proc)
  (call-with-semaphore tag-sema (lambda () (hash-set! tag-table tag proc))))
(define (tag-ref tag)
  (call-with-semaphore tag-sema (lambda () (hash-ref tag-table tag #f))))
(define (tag-clear!)
  (call-with-semaphore tag-sema (lambda () (hash-clear! tag-table))))

;; A singleton ObjC target class whose glazeAction: dispatches by tag.
(define-objc-class GlazeTrayTarget
                   NSObject
                   ()
                   (- _void
                      (glazeAction: [_id sender])
                      (define tag (tell #:type _int sender tag))
                      (define proc (tag-ref tag))
                      (when (procedure? proc)
                        (proc))))

(define glaze-target (tell (tell GlazeTrayTarget alloc) init))

;; The tray handle holds the status item (kept alive) and the current menu.
(struct mac:tray (status-item [menu-box #:mutable]) #:transparent)

(define (supported?)
  (and (eq? (system-type 'os) 'macosx) #t))

;; Create a UTF-8 NSString from a Racket string.
(define (->nsstring s)
  (tell (tell NSString alloc) initWithUTF8String: #:type _string s))

(define (make-tray #:icon icon-path
                   #:tooltip tooltip
                   #:menu items
                   #:on-event [on-event (lambda (e) (void))])
  (unless (supported?)
    (error 'make-tray "macOS tray backend not available on this platform"))

  (define sb (tell NSStatusBar systemStatusBar))
  (define item (tell sb statusItemWithLength: #:type _float NSSquareStatusItemLength))

  ;; Icon.
  (when (and icon-path (file-exists? icon-path))
    (define img
      (tell (tell NSImage alloc) initWithContentsOfFile: #:type _string (path->string icon-path)))
    (tellv img setSize: #:type _NSSize (make-NSSize 18.0 18.0))
    (tellv item setImage: img))

  ;; Tooltip.
  (when (string? tooltip)
    (tellv item setToolTip: (->nsstring tooltip)))

  ;; Menu.
  (define menu (build-menu items))
  (tellv item setMenu: menu)

  (mac:tray item menu))

;; Build an NSMenu from a list of menu-items; assigns tags and registers
;; callbacks. Returns the menu object.
(define (build-menu items)
  (tag-clear!)
  (define menu (tell (tell NSMenu alloc) init))
  (for ([mi (in-list items)])
    (cond
      [(menu-separator? mi) (tellv menu addItem: #:type _id (tell NSMenuItem separatorItem))]
      [else
       (define tag (alloc-tag!))
       (tag-put! tag (menu-item-action mi))
       (define mitem
         (tell (tell NSMenuItem alloc)
               initWithTitle:
               (->nsstring (or (menu-item-label mi) ""))
               action:
               #:type _SEL
               (selector glazeAction:)
               keyEquivalent:
               (->nsstring "")))
       (tellv mitem setTag: #:type _int tag)
       (tellv mitem setTarget: #:type _id glaze-target)
       (tellv menu addItem: #:type _id mitem)]))
  menu)

(define (set-tooltip! t tooltip)
  (when (string? tooltip)
    (tellv (mac:tray-status-item t) setToolTip: (->nsstring tooltip))))

(define (set-icon! t icon-path)
  (when (and icon-path (file-exists? icon-path))
    (define img
      (tell (tell NSImage alloc) initWithContentsOfFile: #:type _string (path->string icon-path)))
    (tellv img setSize: #:type _NSSize (make-NSSize 18.0 18.0))
    (tellv (mac:tray-status-item t) setImage: img)))

(define (set-menu! t items)
  (define menu (build-menu items))
  (set-mac:tray-menu-box! t menu)
  (tellv (mac:tray-status-item t) setMenu: menu))

(define (close t)
  ;; Remove the status item from the bar so the icon disappears. Our strong
  ;; reference in the handle goes away when the caller drops it.
  (define sb (tell NSStatusBar systemStatusBar))
  (tellv sb removeStatusItem: #:type _id (mac:tray-status-item t))
  (tag-clear!))
