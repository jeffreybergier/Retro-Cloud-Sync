#include "RCConnection.h"
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

int RCWaitForSocket(int socketDescriptor, int writeReady,
                           int timeoutSeconds)
{
  fd_set descriptors;
  struct timeval timeout;
  int result;

  FD_ZERO(&descriptors);
  FD_SET(socketDescriptor, &descriptors);
  timeout.tv_sec = timeoutSeconds;
  timeout.tv_usec = 0;
  do {
    if (writeReady) {
      result = select(socketDescriptor + 1, NULL, &descriptors, NULL,
                      &timeout);
    } else {
      result = select(socketDescriptor + 1, &descriptors, NULL, NULL,
                      &timeout);
    }
  } while (result < 0 && errno == EINTR);
  return result;
}

int RCConnectToHost(const char *host, unsigned short port, char *detail, size_t capacity)
{
  struct addrinfo hints;
  struct addrinfo *addresses = NULL;
  struct addrinfo *address;
  char portString[16];
  int remoteSocket = -1;
  int resolverError, lastError = ECONNREFUSED;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  snprintf(portString, sizeof(portString), "%u", (unsigned int)port);
  resolverError = getaddrinfo(host, portString, &hints, &addresses);
  if (resolverError != 0) {
    if (resolverError == EAI_SYSTEM)
      snprintf(detail, capacity, "DNS lookup failed (socket error %d): %s", errno, strerror(errno));
    else snprintf(detail, capacity, "DNS lookup failed (resolver error %d): %s", resolverError, gai_strerror(resolverError));
    return -1;
  }
  for (address = addresses; address != NULL; address = address->ai_next) {
    int flags;
    int connectResult;
    int socketError = 0;
    socklen_t socketErrorLength = sizeof(socketError);

    remoteSocket = socket(address->ai_family, address->ai_socktype,
                          address->ai_protocol);
    if (remoteSocket < 0) {
      lastError = errno;
      continue;
    }
    flags = fcntl(remoteSocket, F_GETFL, 0);
    if (flags >= 0) {
      fcntl(remoteSocket, F_SETFL, flags | O_NONBLOCK);
    }
    connectResult = connect(remoteSocket, address->ai_addr,
                            address->ai_addrlen);
    if (connectResult < 0) {
      lastError = errno;
      if (lastError == EINPROGRESS) {
        int ready = RCWaitForSocket(remoteSocket, 1, 20);
        if (ready == 0) lastError = ETIMEDOUT;
        else if (ready < 0) lastError = errno;
        else if (getsockopt(remoteSocket, SOL_SOCKET, SO_ERROR, &socketError,
                           &socketErrorLength) != 0) lastError = errno;
        else if (socketError) lastError = socketError;
        else connectResult = 0;
      }
    }
    if (flags >= 0) {
      fcntl(remoteSocket, F_SETFL, flags);
    }
    if (connectResult == 0) {
      break;
    }
    close(remoteSocket);
    remoteSocket = -1;
  }
  freeaddrinfo(addresses);
  if (remoteSocket < 0) snprintf(detail, capacity, "TCP connection failed (socket error %d): %s", lastError, strerror(lastError));
  return remoteSocket;
}

