#lang racket/base

(require racket/string
         rackunit
         glaze/api
         glaze/private/native-client
         glaze/types)

(define typed-routes
  (list (GET "/items/:id"
             (lambda (_request id) id)
             #:body-types (list (cons "query" GString))
             #:returns GString)))

(test-case "native client generation binds the declared route"
  (define source (native-api-client-js typed-routes))
  (check-true (string-contains? source "glaze.api ="))
  (check-true (string-contains? source "ItemsId"))
  (check-true (string-contains? source "g.invoke")))

(test-case "native bootstrap exposes transport and stream primitives"
  (check-true (string-contains? native-bootstrap-js "window.__glz1"))
  (check-true (string-contains? native-bootstrap-js "invokeStream"))
  (check-true (string-contains? native-bootstrap-js "window.chrome.webview"))
  (check-true (string-contains? native-bootstrap-js "window.webkit.messageHandlers")))

(test-case "typed declarations come from the same route schema"
  (define declarations (generate-api-declarations typed-routes))
  (check-true (string-contains? declarations "glaze.ItemsId"))
  (check-true (string-contains? declarations "Promise<string>")))
