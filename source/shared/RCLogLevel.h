#ifndef RC_LOG_LEVEL_H
#define RC_LOG_LEVEL_H

/* Shared progress metadata; the portable libraries do not own a log sink. */
typedef enum {
  RCLogDebug = 0,
  RCLogInfo,
  RCLogWarning,
  RCLogError
} RCLogLevel;

#endif
