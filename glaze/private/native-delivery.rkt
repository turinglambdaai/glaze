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

(define (close-port/quietly close-port port)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (close-port port)))

;; Drain one web-server streaming response into native frames. The transport
;; owns the active-stream registry and can supply synchronized registration
;; callbacks so shutdown and cancel never race an unsynchronized hash mutation.
;; The optional defaults preserve the original private helper call shape.
(define (deliver-stream-response! response
                                  id
                                  active-streams
                                  deliver!
                                  #:start-stream!
                                  [start-stream!
                                   (lambda (stream-id port writer-thunk)
                                     (hash-set! active-streams stream-id port)
                                     (thread writer-thunk))]
                                  #:unregister-stream!
                                  [unregister-stream!
                                   (lambda (stream-id)
                                     (hash-remove! active-streams stream-id))]
                                  #:unregister-writer!
                                  [unregister-writer!
                                   (lambda (_stream-id _writer-thread) (void))])
  (define out (response-output response))
  (define-values (pin pout) (make-pipe))
  ;; start-stream! atomically registers the port and starts its writer. A
  ;; transport can reject the start if shutdown has already begun.
  (define writer-thread
    (start-stream!
     id
     pout
     (lambda ()
       (dynamic-wind
        void
        (lambda ()
          ;; Match the HTTP adapter: a writer exception truncates the body.
          ;; Shutdown/cancel may close or kill this writer concurrently.
          (with-handlers ([exn:fail? void])
            (out pout)))
        (lambda ()
          (close-port/quietly close-output-port pout)
          (unregister-writer! id (current-thread))))))
  (if (not writer-thread)
      (begin
        ;; Shutdown won before registration; never run the response writer or
        ;; emit an open frame.
        (close-port/quietly close-input-port pin)
        (close-port/quietly close-output-port pout))
      (dynamic-wind
       void
       (lambda ()
         (deliver! (stream-open-delivery id))
         (let drain ([pending #""])
           (define buf (make-bytes 4096))
           (define n (read-bytes-avail! buf pin))
           (cond
             [(eof-object? n)
              (unless (zero? (bytes-length pending))
                (deliver! (stream-chunk-delivery id (bytes->string/utf-8 pending #\uFFFD))))
              (deliver! (stream-end-delivery id))]
             [(and (exact-nonnegative-integer? n) (> n 0))
              (drain (deliver-utf8! id (bytes-append pending (subbytes buf 0 n)) deliver!))]
             [else (deliver! (stream-end-delivery id))])))
       (lambda ()
         ;; Close ports before removing the registration so shutdown always
         ;; sees a writer until it can no longer produce output.
         (close-port/quietly close-input-port pin)
         (close-port/quietly close-output-port pout)
         (unregister-stream! id))))
  (void)))

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
