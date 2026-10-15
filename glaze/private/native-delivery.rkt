#lang racket/base

;; Native-carrier framing and response draining. This module owns only the
;; bytes/JSON/JavaScript translation at the page boundary. The transport keeps
;; ownership of dispatch, event threads, active-stream storage, and shutdown;
;; callers pass the stream table and delivery callback explicitly.

(require json
         (only-in web-server/http/response-structs response-output)
         "../bridge.rkt")

(provide (struct-out native-delivery)
         response-delivery
         deliver-stream-response!
         event-delivery)

;; Every page delivery has two equivalent carriers: a self-contained script
;; for evaluateJavaScript-style hosts and bare JSON for WebView2's
;; PostWebMessageAsJson.
(struct native-delivery (js json) #:transparent)

(define (response-delivery response)
  (define id (and (hash? response) (hash-ref response 'id #f)))
  (native-delivery (string-append "window.__glz1Deliver && window.__glz1Deliver("
                                  (jsexpr->string (or id "unknown"))
                                  ","
                                  (jsexpr->string (jsexpr->string response))
                                  ");")
                   (jsexpr->string response)))

(define (stream-open-delivery id)
  (native-delivery
   (string-append "window.__glz1StreamOpen && window.__glz1StreamOpen(" (jsexpr->string id) ");")
   (jsexpr->string (hasheq 'glz glz1-version 'stream "open" 'id id))))

(define (stream-chunk-delivery id text)
  (native-delivery (string-append "window.__glz1Chunk && window.__glz1Chunk("
                                  (jsexpr->string id)
                                  ","
                                  (jsexpr->string text)
                                  ");")
                   (jsexpr->string (hasheq 'glz glz1-version 'stream "chunk" 'id id 'text text))))

(define (stream-end-delivery id)
  (native-delivery (string-append "window.__glz1End && window.__glz1End(" (jsexpr->string id) ");")
                   (jsexpr->string (hasheq 'glz glz1-version 'stream "end" 'id id))))

;; Report how much of bs is valid UTF-8 and why conversion stopped. Using the
;; incremental converter status distinguishes an incomplete final sequence
;; (`aborts`) from a byte that can never begin a valid sequence (`error`).
(define (utf8-prefix-status bs)
  (define converter (bytes-open-converter "UTF-8" "UTF-16LE"))
  (define-values (_ converted status) (bytes-convert converter bs))
  (bytes-close-converter converter)
  (values converted status))

;; Deliver as many complete characters as possible. An incomplete suffix is
;; returned for the next pipe read; invalid bytes are emitted with Racket's
;; replacement character and draining continues without stalling.
(define (deliver-utf8! id bs deliver!)
  (let loop ([remaining bs])
    (cond
      [(zero? (bytes-length remaining)) #""]
      [else
       (define-values (valid-length status) (utf8-prefix-status remaining))
       (when (positive? valid-length)
         (deliver! (stream-chunk-delivery id
                                          (bytes->string/utf-8 (subbytes remaining 0 valid-length)))))
       (define tail (subbytes remaining valid-length))
       (case status
         [(complete) #""]
         [(aborts) tail]
         [(error)
          (deliver! (stream-chunk-delivery id (bytes->string/utf-8 (subbytes tail 0 1) #\uFFFD)))
          (loop (subbytes tail 1))]
         [else tail])])))

;; Drain one web-server streaming response into native frames. The caller owns
;; active-streams and uses it for cancellation (id -> output port); this helper
;; registers only for the duration of the stream and always sends open before
;; chunks and end after the pipe reaches EOF.
(define (deliver-stream-response! response id active-streams deliver!)
  (define out (response-output response))
  (define-values (pin pout) (make-pipe))
  (hash-set! active-streams id pout)
  (thread (lambda ()
            ;; Match the HTTP adapter: a writer exception truncates the body. Closing
            ;; the pipe still lets the reader produce the terminal frame.
            (with-handlers ([exn:fail? void])
              (out pout))
            (close-output-port pout)))
  (deliver! (stream-open-delivery id))
  (let drain ([pending #""])
    (define buf (make-bytes 4096))
    (define n (read-bytes-avail! buf pin))
    (cond
      [(eof-object? n)
       (hash-remove! active-streams id)
       (unless (zero? (bytes-length pending))
         (deliver! (stream-chunk-delivery id (bytes->string/utf-8 pending #\uFFFD))))
       (deliver! (stream-end-delivery id))]
      [(and (exact-nonnegative-integer? n) (> n 0))
       (drain (deliver-utf8! id (bytes-append pending (subbytes buf 0 n)) deliver!))]
      [else
       (hash-remove! active-streams id)
       (deliver! (stream-end-delivery id))]))
  (void))

(define (event-delivery seq name data)
  (define batch
    (list seq
          (if (symbol? name)
              (symbol->string name)
              name)
          data))
  (native-delivery
   (string-append "window.__glz1Events && window.__glz1Events(" (jsexpr->string batch) ");")
   (jsexpr->string batch)))
