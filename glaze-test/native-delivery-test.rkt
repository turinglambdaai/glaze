#lang racket/base

;; Direct contract for native framing. Transport lifecycle stays outside this
;; owner; these tests pass delivery callbacks and active-stream tables exactly
;; as native-transport.rkt does.

(require json
         racket/async-channel
         racket/list
         racket/string
         rackunit
         glaze/api
         glaze/bridge
         glaze/private/native-delivery)

(define (delivery-json delivery)
  (string->jsexpr (native-delivery-json delivery)))

(define (chunk-text delivery)
  (define frame (delivery-json delivery))
  (and (hash? frame) (equal? (hash-ref frame 'stream #f) "chunk") (hash-ref frame 'text)))

(test-case "full responses preserve equivalent JavaScript and JSON carriers"
  (define response
    (hasheq 'glz
            1
            'id
            "quote-\"-slash-\\"
            'ok
            #t
            'outcome
            "succeeded"
            'value
            (hasheq 'message "水 and \"quotes\"")))
  (define delivery (response-delivery response))
  (check-equal? (delivery-json delivery) response)
  (check-true (string-contains? (native-delivery-js delivery) "__glz1Deliver"))
  (check-true (string-contains? (native-delivery-js delivery) "quote")))

(test-case "events use one sequenced batch in both carriers"
  ;; __glz1Events JSON.parses its argument, so the js carrier must pass a
  ;; JSON-encoded string and the WebView2 carrier must route through the
  ;; glz envelope's events field; a bare batch is silently dropped.
  (define event (list 7 "counter-changed" (hasheq 'value 2)))
  (define delivery (event-delivery 7 'counter-changed (hasheq 'value 2)))
  ;; the client iterates the batch with ev[1] as the event name, so the
  ;; payload is a batch (array of tuples), not a bare tuple
  (check-equal? (delivery-json delivery) (hasheq 'glz glz1-version 'events (list event)))
  (check-true (string-contains? (native-delivery-js delivery)
                                (jsexpr->string (jsexpr->string (list event)))))
  (check-true (string-contains? (native-delivery-js delivery) "__glz1Events"))
  (check-exn exn:fail? (lambda () (event-delivery 8 'bad (lambda () 'not-json)))))

(test-case "stream draining preserves UTF-8 across writes and frame order"
  (define active-streams (make-hash))
  (define deliveries '())
  (define response
    (streaming-response (lambda (out)
                          (display "A" out)
                          (write-byte #xe6 out)
                          (flush-output out)
                          ;; Force the reader to observe an incomplete three-byte sequence.
                          (sleep 0.05)
                          (write-byte #xb0 out)
                          (write-byte #xb4 out)
                          (display "B" out))))
  (deliver-stream-response! response
                            "utf8"
                            active-streams
                            (lambda (delivery) (set! deliveries (cons delivery deliveries))))
  (set! deliveries (reverse deliveries))
  (check-equal? (hash-ref (delivery-json (first deliveries)) 'stream) "open")
  (check-equal? (hash-ref (delivery-json (last deliveries)) 'stream) "end")
  (check-equal? (apply string-append (filter values (map chunk-text deliveries))) "A水B")
  (check-false (hash-has-key? active-streams "utf8")))

(test-case "invalid UTF-8 is replaced without stalling the stream"
  (define active-streams (make-hash))
  (define deliveries '())
  (deliver-stream-response! (streaming-response (lambda (out)
                                                  (write-bytes (bytes #x61 #xff #x62) out)))
                            "invalid"
                            active-streams
                            (lambda (delivery) (set! deliveries (cons delivery deliveries))))
  (define ordered (reverse deliveries))
  (check-equal? (apply string-append (filter values (map chunk-text ordered))) "a�b")
  (check-equal? (hash-ref (delivery-json (last ordered)) 'stream) "end"))

(test-case "writer failure still terminates and unregisters the stream"
  (define active-streams (make-hash))
  (define deliveries '())
  (deliver-stream-response! (streaming-response (lambda (out)
                                                  (display "partial" out)
                                                  (flush-output out)
                                                  (error 'writer "expected failure")))
                            "failure"
                            active-streams
                            (lambda (delivery) (set! deliveries (cons delivery deliveries))))
  (define ordered (reverse deliveries))
  (check-equal? (apply string-append (filter values (map chunk-text ordered))) "partial")
  (check-equal? (hash-ref (delivery-json (last ordered)) 'stream) "end")
  (check-false (hash-has-key? active-streams "failure")))

(test-case "closing the registered output port cancels and settles a stream"
  (define active-streams (make-hash))
  (define deliveries (make-async-channel))
  (define worker
    (thread (lambda ()
              (deliver-stream-response! (streaming-response (lambda (out)
                                                              (let loop ()
                                                                (display "tick " out)
                                                                (flush-output out)
                                                                (sleep 0.02)
                                                                (loop))))
                                        "cancel"
                                        active-streams
                                        (lambda (delivery)
                                          (async-channel-put deliveries delivery))))))
  (define open-frame (sync/timeout 5 deliveries))
  (check-equal? (hash-ref (delivery-json open-frame) 'stream) "open")
  (check-not-false (sync/timeout 5 deliveries))
  (close-output-port (hash-ref active-streams "cancel"))
  (let wait-for-end ()
    (define delivery (sync/timeout 5 deliveries))
    (check-not-false delivery)
    (unless (equal? (hash-ref (delivery-json delivery) 'stream) "end")
      (wait-for-end)))
  (check-not-false (sync/timeout 5 (thread-dead-evt worker)))
  (check-false (hash-has-key? active-streams "cancel")))
