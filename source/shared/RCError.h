#ifndef RC_ERROR_H
#define RC_ERROR_H

#include <stddef.h>

#define RC_ERROR_MESSAGE_CAPACITY 512

typedef struct {
  int code;
  char message[RC_ERROR_MESSAGE_CAPACITY];
} RCError;

void RCErrorClear(RCError *error);
void RCErrorSet(RCError *error, int code, const char *format, ...);

#endif
