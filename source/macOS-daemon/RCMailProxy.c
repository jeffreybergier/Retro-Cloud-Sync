//
//  RCMailProxy.c
//  RetroCloudSyncDaemon
//

#include "RCMailProxy.h"

#include <AltivecCore/AltivecCore.h>
#include <AltivecCore/openssl/x509v3.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define RC_MAX_LISTENERS 2
#define RC_SMTP_RESPONSE_LIMIT 16384

typedef struct RCProxyConnection RCProxyConnection;

typedef struct {
  struct RCMailProxy *proxy;
  RCMailProxyConfig config;
  int listenerSocket;
  pthread_t thread;
  int threadStarted;
} RCProxyListener;

struct RCProxyConnection {
  struct RCMailProxy *proxy;
  RCMailProxyConfig config;
  int localSocket;
  int remoteSocket;
  RCProxyConnection *next;
};

struct RCMailProxy {
  SSL_CTX *tlsContext;
  RCProxyListener listeners[RC_MAX_LISTENERS];
  size_t listenerCount;
  pthread_mutex_t connectionMutex;
  pthread_cond_t connectionCondition;
  RCProxyConnection *connections;
  int stopping;
};

static void RCLogSocketError(const char *operation, const char *serviceName)
{
  fprintf(stderr, "%s %s failed: %s\n", serviceName, operation,
          strerror(errno));
}

static int RCCreateListener(unsigned short port)
{
  int listenerSocket;
  int reuseAddress = 1;
  struct sockaddr_in address;

  listenerSocket = socket(AF_INET, SOCK_STREAM, 0);
  if (listenerSocket < 0) {
    return -1;
  }
  setsockopt(listenerSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddress,
             sizeof(reuseAddress));
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons(port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(listenerSocket, (struct sockaddr *)&address, sizeof(address)) < 0 ||
      listen(listenerSocket, 16) < 0) {
    close(listenerSocket);
    return -1;
  }
  return listenerSocket;
}

static int RCWaitForSocket(int socketDescriptor, int writeReady,
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

static int RCConnectToHost(const char *host, unsigned short port)
{
  struct addrinfo hints;
  struct addrinfo *addresses = NULL;
  struct addrinfo *address;
  char portString[16];
  int remoteSocket = -1;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  snprintf(portString, sizeof(portString), "%u", (unsigned int)port);
  if (getaddrinfo(host, portString, &hints, &addresses) != 0) {
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
      continue;
    }
    flags = fcntl(remoteSocket, F_GETFL, 0);
    if (flags >= 0) {
      fcntl(remoteSocket, F_SETFL, flags | O_NONBLOCK);
    }
    connectResult = connect(remoteSocket, address->ai_addr,
                            address->ai_addrlen);
    if (connectResult < 0 && errno == EINPROGRESS &&
        RCWaitForSocket(remoteSocket, 1, 20) > 0 &&
        getsockopt(remoteSocket, SOL_SOCKET, SO_ERROR, &socketError,
                   &socketErrorLength) == 0 && socketError == 0) {
      connectResult = 0;
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
  return remoteSocket;
}

static void RCSetSocketTimeouts(int socketDescriptor)
{
  struct timeval timeout;

  timeout.tv_sec = 120;
  timeout.tv_usec = 0;
  setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
             sizeof(timeout));
  setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
             sizeof(timeout));
}

static int RCSendAll(int socketDescriptor, const void *bytes, size_t length)
{
  const unsigned char *cursor = (const unsigned char *)bytes;

  while (length > 0) {
    ssize_t sent = send(socketDescriptor, cursor, length, 0);

    if (sent < 0 && errno == EINTR) {
      continue;
    }
    if (sent <= 0) {
      return 0;
    }
    cursor += sent;
    length -= (size_t)sent;
  }
  return 1;
}

static int RCSSLWriteAll(SSL *tls, const void *bytes, size_t length)
{
  const unsigned char *cursor = (const unsigned char *)bytes;

  while (length > 0) {
    int written = SSL_write(tls, cursor,
                            length > 2147483647U ? 2147483647 : (int)length);

    if (written <= 0) {
      return 0;
    }
    cursor += written;
    length -= (size_t)written;
  }
  return 1;
}

static int RCReadSMTPResponse(int socketDescriptor, int expectedCode,
                              char *savedResponse, size_t savedCapacity,
                              size_t *savedLength, int *hasStartTLS)
{
  char response[RC_SMTP_RESPONSE_LIMIT];
  size_t used = 0;
  size_t lineStart = 0;

  if (savedLength != NULL) {
    *savedLength = 0;
  }
  if (hasStartTLS != NULL) {
    *hasStartTLS = 0;
  }
  while (used + 1 < sizeof(response)) {
    ssize_t received = recv(socketDescriptor, response + used, 1, 0);

    if (received < 0 && errno == EINTR) {
      continue;
    }
    if (received <= 0) {
      return 0;
    }
    used++;
    if (response[used - 1] != '\n') {
      continue;
    }
    response[used] = '\0';
    if (hasStartTLS != NULL && used - lineStart >= 12 &&
        strncasecmp(response + lineStart + 4, "STARTTLS", 8) == 0) {
      *hasStartTLS = 1;
    }
    if (used - lineStart >= 4 &&
        response[lineStart] == (char)('0' + expectedCode / 100) &&
        response[lineStart + 1] ==
            (char)('0' + (expectedCode / 10) % 10) &&
        response[lineStart + 2] == (char)('0' + expectedCode % 10) &&
        response[lineStart + 3] == ' ') {
      if (savedResponse != NULL && savedLength != NULL) {
        size_t copyLength = used < savedCapacity ? used : savedCapacity;

        memcpy(savedResponse, response, copyLength);
        *savedLength = copyLength;
      }
      return 1;
    }
    lineStart = used;
  }
  return 0;
}

static int RCPrepareSMTPStartTLS(int remoteSocket, char *greeting,
                                 size_t greetingCapacity,
                                 size_t *greetingLength)
{
  static const char hello[] = "EHLO localhost\r\n";
  static const char startTLS[] = "STARTTLS\r\n";
  int hasStartTLS = 0;

  if (!RCReadSMTPResponse(remoteSocket, 220, greeting, greetingCapacity,
                          greetingLength, NULL) ||
      !RCSendAll(remoteSocket, hello, sizeof(hello) - 1) ||
      !RCReadSMTPResponse(remoteSocket, 250, NULL, 0, NULL, &hasStartTLS) ||
      !hasStartTLS ||
      !RCSendAll(remoteSocket, startTLS, sizeof(startTLS) - 1) ||
      !RCReadSMTPResponse(remoteSocket, 220, NULL, 0, NULL, NULL)) {
    return 0;
  }
  return 1;
}

static SSL *RCConnectTLS(SSL_CTX *context, int remoteSocket,
                         const char *remoteHost)
{
  SSL *tls = SSL_new(context);
  X509_VERIFY_PARAM *parameters;

  if (tls == NULL) {
    return NULL;
  }
  parameters = SSL_get0_param(tls);
  X509_VERIFY_PARAM_set_hostflags(parameters,
                                  X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
  if (SSL_set_tlsext_host_name(tls, remoteHost) != 1 ||
      X509_VERIFY_PARAM_set1_host(parameters, remoteHost, 0) != 1 ||
      SSL_set_fd(tls, remoteSocket) != 1 || SSL_connect(tls) != 1 ||
      SSL_get_verify_result(tls) != X509_V_OK) {
    SSL_free(tls);
    return NULL;
  }
  return tls;
}

static int RCRelayConnection(int localSocket, int remoteSocket, SSL *tls)
{
  unsigned char buffer[16384];

  for (;;) {
    fd_set readable;
    struct timeval timeout;
    int maximumSocket = localSocket > remoteSocket ? localSocket : remoteSocket;
    int result;

    FD_ZERO(&readable);
    FD_SET(localSocket, &readable);
    FD_SET(remoteSocket, &readable);
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    if (SSL_pending(tls) > 0) {
      result = 1;
      FD_CLR(localSocket, &readable);
    } else {
      do {
        result = select(maximumSocket + 1, &readable, NULL, NULL, &timeout);
      } while (result < 0 && errno == EINTR);
    }
    if (result < 0) {
      return 0;
    }
    if (result == 0) {
      continue;
    }
    if (FD_ISSET(localSocket, &readable)) {
      ssize_t received = recv(localSocket, buffer, sizeof(buffer), 0);

      if (received <= 0 ||
          !RCSSLWriteAll(tls, buffer, (size_t)received)) {
        return received == 0;
      }
    }
    if (SSL_pending(tls) > 0 || FD_ISSET(remoteSocket, &readable)) {
      int received = SSL_read(tls, buffer, sizeof(buffer));

      if (received <= 0 || !RCSendAll(localSocket, buffer, (size_t)received)) {
        return received == 0;
      }
    }
  }
}

static void RCRemoveConnection(RCProxyConnection *connection)
{
  RCMailProxy *proxy = connection->proxy;
  RCProxyConnection **cursor;

  pthread_mutex_lock(&proxy->connectionMutex);
  cursor = &proxy->connections;
  while (*cursor != NULL && *cursor != connection) {
    cursor = &(*cursor)->next;
  }
  if (*cursor == connection) {
    *cursor = connection->next;
  }
  pthread_cond_broadcast(&proxy->connectionCondition);
  pthread_mutex_unlock(&proxy->connectionMutex);
}

static void *RCConnectionMain(void *argument)
{
  RCProxyConnection *connection = (RCProxyConnection *)argument;
  RCMailProxy *proxy = connection->proxy;
  char greeting[RC_SMTP_RESPONSE_LIMIT];
  size_t greetingLength = 0;
  SSL *tls = NULL;
  int remoteSocket;
  int stopping;

  remoteSocket = RCConnectToHost(connection->config.remoteHost,
                                 connection->config.remotePort);
  pthread_mutex_lock(&proxy->connectionMutex);
  connection->remoteSocket = remoteSocket;
  stopping = proxy->stopping;
  pthread_mutex_unlock(&proxy->connectionMutex);
  if (connection->remoteSocket < 0) {
    RCLogSocketError("remote connection", connection->config.serviceName);
    goto finished;
  }
  if (stopping) {
    goto finished;
  }
  RCSetSocketTimeouts(connection->localSocket);
  RCSetSocketTimeouts(connection->remoteSocket);
  if (connection->config.mode == kRCMailProxySMTPStartTLS &&
      !RCPrepareSMTPStartTLS(connection->remoteSocket, greeting,
                             sizeof(greeting), &greetingLength)) {
    fprintf(stderr, "%s upstream STARTTLS negotiation failed\n",
            connection->config.serviceName);
    goto finished;
  }
  tls = RCConnectTLS(proxy->tlsContext, connection->remoteSocket,
                     connection->config.remoteHost);
  if (tls == NULL) {
    fprintf(stderr, "%s verified TLS connection failed\n",
            connection->config.serviceName);
    ERR_print_errors_fp(stderr);
    goto finished;
  }
  if (greetingLength > 0 &&
      !RCSendAll(connection->localSocket, greeting, greetingLength)) {
    goto finished;
  }
  fprintf(stderr, "%s proxy connection established\n",
          connection->config.serviceName);
  RCRelayConnection(connection->localSocket, connection->remoteSocket, tls);

finished:
  if (tls != NULL) {
    SSL_shutdown(tls);
    SSL_free(tls);
  }
  if (connection->remoteSocket >= 0) {
    close(connection->remoteSocket);
  }
  close(connection->localSocket);
  RCRemoveConnection(connection);
  free(connection);
  return NULL;
}

static int RCProxyIsStopping(RCMailProxy *proxy)
{
  int stopping;

  pthread_mutex_lock(&proxy->connectionMutex);
  stopping = proxy->stopping;
  pthread_mutex_unlock(&proxy->connectionMutex);
  return stopping;
}

static void *RCListenerMain(void *argument)
{
  RCProxyListener *listener = (RCProxyListener *)argument;
  RCMailProxy *proxy = listener->proxy;

  while (!RCProxyIsStopping(proxy)) {
    int ready = RCWaitForSocket(listener->listenerSocket, 0, 1);
    int localSocket;
    RCProxyConnection *connection;
    pthread_t connectionThread;

    if (ready <= 0) {
      continue;
    }
    localSocket = accept(listener->listenerSocket, NULL, NULL);
    if (localSocket < 0) {
      if (errno != EINTR) {
        RCLogSocketError("accept", listener->config.serviceName);
      }
      continue;
    }
    connection = (RCProxyConnection *)calloc(1, sizeof(*connection));
    if (connection == NULL) {
      close(localSocket);
      continue;
    }
    connection->proxy = proxy;
    connection->config = listener->config;
    connection->localSocket = localSocket;
    connection->remoteSocket = -1;
    pthread_mutex_lock(&proxy->connectionMutex);
    connection->next = proxy->connections;
    proxy->connections = connection;
    pthread_mutex_unlock(&proxy->connectionMutex);
    if (pthread_create(&connectionThread, NULL, RCConnectionMain,
                       connection) != 0) {
      RCRemoveConnection(connection);
      close(localSocket);
      free(connection);
      continue;
    }
    pthread_detach(connectionThread);
  }
  return NULL;
}

RCMailProxy *RCMailProxyStart(const RCMailProxyConfig *configs,
                             size_t configCount,
                             const char *certificatePath)
{
  RCMailProxy *proxy;
  size_t index;

  if (configs == NULL || configCount == 0 ||
      configCount > RC_MAX_LISTENERS || certificatePath == NULL) {
    return NULL;
  }
  proxy = (RCMailProxy *)calloc(1, sizeof(*proxy));
  if (proxy == NULL) {
    return NULL;
  }
  pthread_mutex_init(&proxy->connectionMutex, NULL);
  pthread_cond_init(&proxy->connectionCondition, NULL);
  proxy->tlsContext = SSL_CTX_new(TLS_client_method());
  if (proxy->tlsContext == NULL ||
      SSL_CTX_set_min_proto_version(proxy->tlsContext, TLS1_2_VERSION) != 1 ||
      SSL_CTX_load_verify_locations(proxy->tlsContext, certificatePath,
                                    NULL) != 1) {
    fprintf(stderr, "Could not configure the mail proxy TLS context\n");
    ERR_print_errors_fp(stderr);
    RCMailProxyStop(proxy);
    return NULL;
  }
  SSL_CTX_set_verify(proxy->tlsContext, SSL_VERIFY_PEER, NULL);

  for (index = 0; index < configCount; index++) {
    RCProxyListener *listener = &proxy->listeners[index];

    listener->proxy = proxy;
    listener->config = configs[index];
    listener->listenerSocket = RCCreateListener(configs[index].localPort);
    if (listener->listenerSocket < 0) {
      RCLogSocketError("listener setup", configs[index].serviceName);
      RCMailProxyStop(proxy);
      return NULL;
    }
    proxy->listenerCount++;
    if (pthread_create(&listener->thread, NULL, RCListenerMain, listener) !=
        0) {
      fprintf(stderr, "%s listener thread creation failed\n",
              configs[index].serviceName);
      RCMailProxyStop(proxy);
      return NULL;
    }
    listener->threadStarted = 1;
    fprintf(stderr, "%s listening on 127.0.0.1:%u -> %s:%u\n",
            configs[index].serviceName,
            (unsigned int)configs[index].localPort, configs[index].remoteHost,
            (unsigned int)configs[index].remotePort);
  }
  return proxy;
}

void RCMailProxyStop(RCMailProxy *proxy)
{
  size_t index;

  if (proxy == NULL) {
    return;
  }
  pthread_mutex_lock(&proxy->connectionMutex);
  proxy->stopping = 1;
  pthread_mutex_unlock(&proxy->connectionMutex);
  for (index = 0; index < proxy->listenerCount; index++) {
    if (proxy->listeners[index].threadStarted) {
      pthread_join(proxy->listeners[index].thread, NULL);
    }
    if (proxy->listeners[index].listenerSocket >= 0) {
      close(proxy->listeners[index].listenerSocket);
      proxy->listeners[index].listenerSocket = -1;
    }
  }

  pthread_mutex_lock(&proxy->connectionMutex);
  while (proxy->connections != NULL) {
    RCProxyConnection *connection;

    for (connection = proxy->connections; connection != NULL;
         connection = connection->next) {
      shutdown(connection->localSocket, SHUT_RDWR);
      if (connection->remoteSocket >= 0) {
        shutdown(connection->remoteSocket, SHUT_RDWR);
      }
    }
    pthread_cond_wait(&proxy->connectionCondition,
                      &proxy->connectionMutex);
  }
  pthread_mutex_unlock(&proxy->connectionMutex);
  if (proxy->tlsContext != NULL) {
    SSL_CTX_free(proxy->tlsContext);
  }
  pthread_cond_destroy(&proxy->connectionCondition);
  pthread_mutex_destroy(&proxy->connectionMutex);
  free(proxy);
}
