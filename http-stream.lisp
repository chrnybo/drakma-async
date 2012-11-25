(in-package :drakma-async)

(define-condition http-eof (http-error) ()
  (:report (lambda (c s) (format s "HTTP connection EOF: ~a: ~a" (conn-errcode c) (conn-errmsg c))))
  (:documentation "Passed to an event callback when an HTTP peer closes the connection."))

(defparameter *scanner-header-parse-line*
  (cl-ppcre:create-scanner "\\r\\n" :multi-line-mode t)
  "Create a regex scanner for splitting header lines up.")
(defparameter *scanner-header-parse-kv*
  (cl-ppcre:create-scanner ":[ \s]+" :multi-line-mode t)
  "Create a regex scanner for splitting header kv pairs up.")
(defparameter *scanner-numeric*
  (cl-ppcre:create-scanner "^[0-9\.]+$")
  "Create a regex scanner that detects if a string can be converted to a numver.")
(defparameter *scanner-status-not-100-continue*
  (cl-ppcre:create-scanner "^HTTP/[0-9\\.]+ (?!(100 Continue))" :case-insensitive-mode t)
  "Create a scanner to determine if a response line is a status line.")

(defun find-non-whitespace-pos (seq)
  "Find the position of the first non-whitespace character in a sequence."
  (loop for i from 0
        for byte across seq do
    (unless (or (= byte 9)
                (= byte 10)
                (= byte 13)
                (= byte 32))
      (return-from find-non-whitespace-pos i))))

(defun get-headers-from-response (bytes)
  "Given a full response body, pull out the section that contains only the
   headers."
  (let ((search-section-end (make-array 4 :element-type '(unsigned-byte 8) :initial-contents #(13 10 13 10)))
        (last-line-end 0)
        (bytes-length (length bytes)))
    ;; loop over each line without doing any parsing/splitting to do it
    (loop for search-pos = (min last-line-end bytes-length)
          for pos = (or (search #(13 10) bytes :start2 search-pos) last-line-end)
          for line = (if (= last-line-end pos)
                         (make-array 0 :element-type '(unsigned-byte 8))
                         (subseq bytes last-line-end pos)) do
      (when (< bytes-length last-line-end)
        ;; no deal
        (return))
      (setf last-line-end (+ 2 pos))
      ;; test if we got a status line that isn't "100 Continue"
      (when (cl-ppcre:scan *scanner-status-not-100-continue* (babel:octets-to-string line))
        ;; we only want the headers, not the status line
        (let* ((next-line (+ 2 (search #(13 10) bytes :start2 pos)))
               (section-end (search search-section-end
                                    bytes
                                    :start2 next-line)))
          (return-from get-headers-from-response
                       (values 
                         (subseq bytes next-line section-end)
                         (+ section-end 4))))))))

(defun parse-headers (bytes)
  "Attempt to pull out headers in a plist from a sequence."
  (multiple-value-bind (header-bytes body-start-pos)
      (get-headers-from-response bytes)
    (let* ((header-str (when header-bytes (babel:octets-to-string header-bytes))))
      (when header-str
        (values
          (loop for line in (cl-ppcre:split *scanner-header-parse-line* header-str)
                append (let* ((kv (cl-ppcre:split *scanner-header-parse-kv* line))
                              (numberp (cl-ppcre:scan *scanner-numeric* (cadr kv)))
                              (val (if numberp
                                       (read-from-string (cadr kv))
                                       (string-downcase (cadr kv)))))
                         (list (intern (string-upcase (car kv)) :keyword)
                               val)))
          body-start-pos)))))

(defun make-http-parser (&key (buffer-size 8192))
  "Return a function that accepts a byte array. This byte array is analyzed to
   see if a full HTTP response has been passed in. If so, the parser returns the
   first value of T and a second value of the entire response as a byte array,
   otherwise returns NIL."
  (let ((response-bytes (make-array buffer-size :adjustable t :element-type '(unsigned-byte 8)))
        (search-line-end  (make-array 2 :element-type '(unsigned-byte 8) :initial-contents #(13 10)))
        (cur-pos 0)
        (have-headers nil)
        (content-length nil)
        (parsing-body nil)
        (chunked nil)
        (chunk-start nil)
        (body-start nil))
    (lambda (data)
      (block parser-wrap
        (when (eql data :eof)
          (return-from parser-wrap
                       (values t (subseq response-bytes 0 cur-pos))))
        ;; append the data
        (let ((data-length (length data)))
          ;; adjust the buffer to hold more if needed
          (when (< buffer-size (+ cur-pos data-length))
            (let ((size (* buffer-size (1+ (floor (/ (+ (length response-bytes) data-length) buffer-size))))))
              (setf response-bytes (adjust-array response-bytes size))))
          (replace response-bytes data :start1 cur-pos)
          (incf cur-pos data-length))
        ;; grab the headers. if we have an entire block of headers, we can move
        ;; on to parse the body
        (unless have-headers
          (multiple-value-bind (headers body-start-pos)
              (parse-headers (subseq response-bytes 0 cur-pos))
            (let ((content-length-value (getf headers :content-length))
                  (transfer-encoding-value (getf headers :transfer-encoding)))
              (when headers
                (setf body-start body-start-pos
                      chunk-start body-start
                      have-headers t
                      parsing-body t)
                (cond
                  ;; we have a content length. this makes things easy
                  (content-length-value
                    (setf content-length content-length-value)
                    nil)
                  ;; we're chunking. great...
                  ((string= transfer-encoding-value "chunked")
                   (setf chunked t)
                   nil)
                  ;; no content-length or chunking? assume no body.
                  (t
                   (return-from parser-wrap
                                (values t (subseq response-bytes 0 body-start-pos)))))))))
        (when parsing-body
          (cond 
            (chunked
              (let ((last-chunk-start -1))
                ;; loop over all available chunks until we get a partial
                (loop while (not (= last-chunk-start chunk-start)) do
                  (setf last-chunk-start chunk-start)
                  (let* ((chunk-blob (subseq response-bytes chunk-start cur-pos))
                         (chunk-length-seq-start (or (find-non-whitespace-pos chunk-blob) 0))
                         (chunk-length-seq-end (search search-line-end chunk-blob :start2 chunk-length-seq-start))
                         ;(lol (format t "length start/end: ~a/~a~%" chunk-length-seq-start chunk-length-seq-end))
                         (chunk-length-seq (subseq chunk-blob chunk-length-seq-start chunk-length-seq-end))
                         ;(lol (if (< 12 (length chunk-blob))
                         ;         (subseq chunk-blob 0 12)
                         ;         chunk-blob))
                         ;(lol (format t "CHUNK BEG: ~a ~a (~s)~%" (find-non-whitespace-pos chunk-blob) lol (babel:octets-to-string lol)))
                         ;(lol (format t "CHUNK BEG: ~s~%" (babel:octets-to-string chunk-length-seq)))
                         (chunk-length (ignore-errors
                                         (parse-integer
                                           (babel:octets-to-string chunk-length-seq)
                                           :radix 16)))
                         (chunk-start-pos (+ chunk-length-seq-end 2))
                         ;(lol (format t "calculating chunk: ~a + ~a~%" chunk-start-pos chunk-length))
                         (chunk (subseq chunk-blob chunk-start-pos (min (length chunk-blob) (+ chunk-start-pos (or chunk-length 0))))))
                    ;(format t "chunk (~s): ~a~%" (length chunk-blob) (subseq (babel:octets-to-string chunk) 0 (min (or chunk-length 0) 60)))
                    (cond
                      ((eq chunk-length 0)
                       ;(format t "zero chunk~%")
                       (return-from parser-wrap (values t (subseq response-bytes 0 cur-pos))))
                      ((numberp chunk-length)
                       ;(format t "chunk length: ~a/~a~%" (length chunk) chunk-length)
                       (when (<= chunk-length (length chunk))
                         (setf chunk-start (+ chunk-start chunk-length chunk-start-pos))))
                      (t
                       (return))))
                  ;(format t "last-chunk/start: ~a/~a~%" last-chunk-start chunk-start)
                  )))
            (content-length
              (let* ((body (subseq response-bytes body-start cur-pos))
                     (body-length (length body)))
                (when (<= content-length (length body))
                  (return-from parser-wrap
                               (values t (if (= body-length content-length)
                                             (subseq response-bytes 0 cur-pos)
                                             (subseq response-bytes 0 (+ body-start content-length))))))))
            (t
              (error "Got neither Content-Length nor chunked transfer."))))))))
    
(defun http-request-complete-stream (uri request-cb event-cb &key timeout)
  "Open a TCP stream to the given uri, determine when a full response has been
   returned from the host, and then fire the complete callback, at which point
   the response can be read from the stream."
  (check-event-loop-running)
  (let* ((parsed-uri (puri:parse-uri uri))
         (host (puri:uri-host parsed-uri))
         (port (or (puri:uri-port parsed-uri) 80))
         (http-parser (make-http-parser))
         (response-finished-p nil))
    (flet ((finish-request (sock data)
             (multiple-value-bind (finishedp response-data)
                 (funcall http-parser data)
               (when (and finishedp (not response-finished-p))  ; only "finish" once
                 ;; we have a finished response. grab all trailing data off of the
                 ;; evbuffer (if there is any), write our entire response data to the
                 ;; evbuffer, then write whatever extra data we just pulled off onto
                 ;; the end. this gives us the ability to wrap a stream around the
                 ;; entire response + whatever extra data there is and ship it off to
                 ;; whoever's interested in it.
                 (setf response-finished-p t)
                 (let ((evbuf (le:bufferevent-get-input (socket-c sock)))
                       (remaining-buffer-data nil))
                   ;; if the evbuffer has a length > 0, grab any data left on it
                   (unless (eq (le:evbuffer-get-length evbuf) 0)
                     (setf remaining-buffer-data (drain-evbuffer evbuf)))
                   ;; write the response + any extra data back into the evbuffer
                   (le:evbuffer-unfreeze evbuf 0)  ; input buffers by default disable writing
                   (write-to-evbuffer evbuf response-data)
                   (le:evbuffer-freeze evbuf 0)  ; re-enable write freeze
                   (when remaining-buffer-data
                     ;; write existing data back onto end of evbuffer
                     (write-to-evbuffer evbuf remaining-buffer-data)))
                 ;; create a stream and send it to the request-cb
                 (let ((stream (make-instance 'async-io-stream :socket sock)))
                   (funcall request-cb stream))))))
      (tcp-send host port nil
        ;; drai the bufferevent, and parse all the aquired data. once we have a
        ;; full response, pump the data back into the bufferevent's output buffer
        ;; and call out finish-cb with an async-io-stream wrapping the socket.
        (lambda (sock data)
          (finish-request sock data))
        ;; Wrap the event handler to catch EOF events (if a server sends
        ;; EOF, the response is done sending).
        (lambda (ev)
          (handler-case (error ev)
            (tcp-eof ()
              (let ((sock (tcp-socket ev)))
                (finish-request sock :eof))
              (funcall event-cb (make-instance 'http-eof
                                               :code -1
                                               :msg "HTTP stream client peer closed connection.")))
            (tcp-timeout ()
              (funcall event-cb (make-instance 'http-timeout
                                               :code -1
                                               :msg "HTTP stream client timed out.")))
            (t ()
              (funcall event-cb ev))))
        :read-timeout timeout
        :stream t))))
