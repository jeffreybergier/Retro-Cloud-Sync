#include "RCError.h"

#include <stdarg.h>
#include <stdio.h>

void RCErrorClear(RCError *error)
{
  if (error != NULL) {
    error->code = 0;
    error->message[0] = '\0';
  }
}

void RCErrorSet(RCError *error, int code, const char *format, ...)
{
  va_list arguments;

  if (error == NULL) {
    return;
  }
  error->code = code;
  va_start(arguments, format);
  vsnprintf(error->message, sizeof(error->message), format, arguments);
  va_end(arguments);
  error->message[sizeof(error->message) - 1] = '\0';
}
