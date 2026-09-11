#ifndef RC_ERROR_H
#define RC_ERROR_H

#include <stddef.h>
#include <signal.h>

#define RC_ERROR_MESSAGE_CAPACITY 512

typedef struct {
  int code;
  char message[RC_ERROR_MESSAGE_CAPACITY];
} RCError;

/* Process-wide cooperative shutdown. Only the signal handler sets this flag;
   tests may reset it between isolated cases. Default zero keeps probes unchanged. */
extern volatile sig_atomic_t RCStopRequested;
#define RC_ERROR_CANCELLED (-9999)
int RCCheckCancellation(RCError *error);

void RCErrorClear(RCError *error);
void RCErrorSet(RCError *error, int code, const char *format, ...);

#endif
