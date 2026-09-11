//
//  RCMailProxy.h
//  RetroCloudSyncDaemon
//

#ifndef RC_MAIL_PROXY_H
#define RC_MAIL_PROXY_H

#include <stddef.h>

typedef enum {
  kRCMailProxyImplicitTLS = 0,
  kRCMailProxySMTPStartTLS = 1
} RCMailProxyMode;

typedef struct {
  const char *serviceName;
  unsigned short localPort;
  const char *remoteHost;
  unsigned short remotePort;
  RCMailProxyMode mode;
} RCMailProxyConfig;

typedef struct RCMailProxy RCMailProxy;

// Starts loopback listeners for all entries in |configs|.
RCMailProxy *RCMailProxyStart(const RCMailProxyConfig *configs,
                             size_t configCount,
                             const char *certificatePath);

// Stops listeners and active connections, then releases |proxy|.
void RCMailProxyRequestStop(RCMailProxy *proxy);
void RCMailProxyStop(RCMailProxy *proxy);
/* Only when the caller will immediately exit the process. */
void RCMailProxyStopForExit(RCMailProxy *proxy);

#endif  // RC_MAIL_PROXY_H
