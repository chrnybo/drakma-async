(in-package :drakma-async)

(defun http-async (uri &rest args
                       &key (protocol :http/1.1)
                            (method :get)
                            force-ssl
                            certificate
                            key
                            certificate-password
                            verify
                            max-depth
                            ca-file
                            ca-directory
                            parameters
                            content
                            (content-type "application/x-www-form-urlencoded")
                            (content-length nil content-length-provided-p)
                            form-data
                            cookie-jar
                            basic-authorization
                            (user-agent :drakma)
                            (accept "*/*")
                            range
                            proxy
                            proxy-basic-authorization
                            additional-headers
                            (redirect 5)
                            (redirect-methods '(:get :head))
                            auto-referer
                            keep-alive
                            (close t)
                            (external-format-out *drakma-default-external-format*)
                            (external-format-in *drakma-default-external-format*)
                            force-binary
                            want-stream
                            stream
                            preserve-uri
                            #+(or abcl clisp lispworks mcl openmcl sbcl)
                            (connection-timeout 20)
                            #+:lispworks (read-timeout 20)
                            #+(and :lispworks (not :lw-does-not-have-write-timeout))
                            (write-timeout 20 write-timeout-provided-p)
                            #+:openmcl
                            deadline)
  "This function wraps drakma's new http-request-async function so you don't
   have to deal with the intricacies. For full documentation on this function,
   refer to the docs for drakma:http-request, since most parameters are the
   same. There are a few parameters that are controlled by this function fully,
   in particular:
     :close
       Always set to nil. This function will handling closing.
     :want-stream
       Always set to nil. We'll use our own stream.
     :stream
       We pass in our own stream, so you are not allowed to.

   This function returns a cl-async future, to which one or more callbacks can
   be attached. The callbacks must take the same arguments as the return values
   of drakma:http-request:
     (body status headers uri stream must-close status-text)

   The callbacks will be called when the request completes."
  ;; TODO: allow passing in of TCP stream so more than one request can happen on
  ;; a socket
  (let* ((future (make-future))
         ;; filled in later
         (finish-cb nil)
         ;; create an http-stream we can drain data from once a response comes in
         (stream (http-request-complete-stream
                   uri
                   (lambda (stream)
                     (funcall finish-cb stream))
                   (lambda (ev)
                     (signal-error future ev))
                   :timeout (if (boundp 'connection-timeout)
                                connection-timeout
                                20)))
         ;; make a drakma-specific stream.
         (http-stream (make-flexi-stream (chunga:make-chunked-stream stream) :external-format :latin-1))
         ;; call *our* version of http-request which we defined above, making
         ;; sure we save the resulting callback.
         (req-cb (apply
                   #'drakma::http-request-async
                   (append
                     (list uri
                           :close nil
                           :want-stream nil
                           :stream http-stream)
                     args))))
    ;; overwrite the socket's read callback to handle req-cb and finish the
    ;; future with the computed values.
    (setf finish-cb (lambda (stream)
                      (let ((http-values (multiple-value-list (funcall req-cb))))
                        ;; if we got a function back, it means we redirected and
                        ;; the original stream was reused, meaning the callbacks
                        ;; will still function fine. take no action. otherwise,
                        ;; either finish the future, or if another future is
                        ;; returned, rebind the original future's callbacks to
                        ;; the new one.
                        (unless (functionp (car http-values))
                          (unless (as:socket-closed-p (as:stream-socket stream))
                            (close stream))
                          (apply #'finish (append (list future) http-values))))))
    ;; let the app attach callbacks to the future
    future))
