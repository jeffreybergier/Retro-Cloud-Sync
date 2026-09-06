#ifndef RC_MAIL_PROXY_LOG_H
#define RC_MAIL_PROXY_LOG_H

/* The mail proxy's only logging boundary into Objective-C. Pass a complete
   UTF-8 message without a trailing newline, not a format string. This call is
   synchronous and may be made from a pthread; ownership stays with the caller.
   Keep this header free of Foundation types and Objective-C declarations. */
void RCMailProxyLogMessage(const char *message);

#endif
