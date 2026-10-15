#lang racket/base

;; Direct policy tests for the HTTP development adapter trust boundary.

(require rackunit
         glaze/private/http-security)

(test-case "only literal loopback Host values pass"
  (for ([host (in-list '("localhost"
                         "LOCALHOST:8080"
                         "127.0.0.1"
                         "127.0.0.1:65535"
                         "[::1]"
                         "[::1]:9000"
                         "::1"))])
    (check-true (loopback-host-value? host) host))
  (for ([host (in-list '("example.test"
                         "localhost.example.test"
                         "127.0.0.1.example.test"
                         "[::1].example.test"
                         "127.0.0.2"
                         ""))])
    (check-false (loopback-host-value? host) host)))

(test-case "Content-Length policy rejects only valid oversized lengths"
  (check-false (content-length-too-large? #f 100))
  (check-false (content-length-too-large? "100" 100))
  (check-true (content-length-too-large? " 101 " 100))
  (check-false (content-length-too-large? "-1" 100))
  (check-false (content-length-too-large? "garbage" 100)))

(test-case "Origin and Fetch Metadata agree on the loopback server origin"
  (check-false (cross-site-values? "http://127.0.0.1:8123" #f 8123))
  (check-false (cross-site-values? "http://localhost:8123" "cross-site" 8123)
               "a valid Origin is authoritative")
  (check-true (cross-site-values? "https://localhost:8123" #f 8123))
  (check-true (cross-site-values? "http://127.0.0.1:9" #f 8123))
  (check-true (cross-site-values? "not a URL" #f 8123))
  (check-false (cross-site-values? #f "same-origin" 8123))
  (check-false (cross-site-values? #f "none" 8123))
  (check-true (cross-site-values? #f "cross-site" 8123))
  (check-false (cross-site-values? #f #f 8123)))

(test-case "header or exact cookie token authorizes, including padded tokens"
  (check-true (token-values-match? "secret" #f "secret"))
  (check-true (token-values-match? #f "a=1; glaze_token=abc==; theme=dark" "abc=="))
  (check-false (token-values-match? "wrong" "glaze_token=also-wrong" "secret"))
  (check-false (token-values-match? #f "other=secret" "secret")))
