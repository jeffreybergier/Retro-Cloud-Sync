#ifndef RC_CONNECTION_H
#define RC_CONNECTION_H
#include <stddef.h>
/* Returns a connected descriptor owned by the caller, or -1 with diagnostic. */
int RCConnectToHost(const char *host, unsigned short port, char *detail, size_t capacity);
int RCWaitForSocket(int socketDescriptor, int writeReady, int timeoutSeconds);
#endif
