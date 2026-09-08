#include <netdb.h>
#include <string.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/socket.h>

/* Inject deterministic OS results into the production connection helper.
   No external network, listeners, or timing assumptions are needed. */
static int simulateTimeout;
static int TestGetAddrInfo(const char *host, const char *port,
    const struct addrinfo *hints, struct addrinfo **result)
{
  if (!strcmp(host, "test.invalid")) return EAI_NONAME;
  return getaddrinfo(host, port, hints, result);
}
static int TestConnect(int fd, const struct sockaddr *address, socklen_t length)
{
  (void)fd; (void)address; (void)length;
  errno = EINPROGRESS; return -1;
}
static int TestSelect(int n, fd_set *r, fd_set *w, fd_set *e, struct timeval *t)
{
  (void)n; (void)r; (void)w; (void)e; (void)t;
  return simulateTimeout ? 0 : 1;
}
static int TestGetSockOpt(int fd, int level, int name, void *value, socklen_t *length)
{
  (void)fd; (void)level; (void)name; (void)length;
  *(int *)value = ECONNREFUSED; return 0;
}
#define getaddrinfo TestGetAddrInfo
#define connect TestConnect
#define select TestSelect
#define getsockopt TestGetSockOpt
#include "../../../macOS-daemon/RCMailProxy.c"
#undef getaddrinfo
#undef connect
#undef select
#undef getsockopt

int RCMailLoggingTests(void)
{
  char detail[256];
  errno = EBUSY;
  if (RCConnectToHost("test.invalid", 993, detail, sizeof(detail)) != -1 ||
      !strstr(detail, "resolver error")) {
    fprintf(stderr, "DNS diagnostic: %s\n", detail); return 0;
  }
  if (RCConnectToHost("127.0.0.1", 993, detail, sizeof(detail)) != -1 ||
      !strstr(detail, strerror(ECONNREFUSED))) {
    fprintf(stderr, "TCP diagnostic: %s\n", detail); return 0;
  }
  simulateTimeout = 1;
  if (RCConnectToHost("127.0.0.1", 993, detail, sizeof(detail)) != -1 ||
      !strstr(detail, strerror(ETIMEDOUT))) {
    fprintf(stderr, "Timeout diagnostic: %s\n", detail); return 0;
  }
  return 1;
}
