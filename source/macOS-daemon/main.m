//
//  main.m
//  RetroCloudSyncDaemon
//

#import <Foundation/Foundation.h>
#import <AltivecCore/AltivecCore.h>

#include "RCMailProxy.h"

#include <signal.h>
#include <stdio.h>
#include <string.h>

static const char kRCNetworkTestURL[] =
    "https://platform.theverge.com/wp-content/uploads/sites/2/2026/07/"
    "gettyimages-2282688394.jpg?quality=90&strip=all&"
    "crop=16.67%2C0%2C66.66%2C100&w=1440";
static NSString * const kRCCertificateName = @"cacert.pem";
static NSString * const kRCNetworkTestName = @"RetroCloudSyncNetworkTest.jpg";

static const unsigned short kRCIMAPLocalPort = 1143;
static const char kRCIMAPServer[] = "imap.mail.me.com";
static const unsigned short kRCIMAPServerPort = 993;
static const unsigned short kRCSMTPLocalPort = 1587;
static const char kRCSMTPServer[] = "smtp.mail.me.com";
static const unsigned short kRCSMTPServerPort = 587;

static volatile sig_atomic_t gShouldKeepRunning = 1;

static void HandleTerminationSignal(int signalNumber)
{
  (void)signalNumber;
  gShouldKeepRunning = 0;
}

static BOOL DownloadNetworkTest(const char *executablePath)
{
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *daemonPath = [NSString stringWithUTF8String:executablePath];
  NSString *daemonDirectory = [daemonPath stringByDeletingLastPathComponent];
  NSString *certificatePath = [daemonDirectory
      stringByAppendingPathComponent:kRCCertificateName];
  NSString *outputPath = [daemonDirectory
      stringByAppendingPathComponent:kRCNetworkTestName];
  NSString *temporaryPath = [outputPath stringByAppendingString:@".download"];
  CURL *curl;
  CURLcode result;
  FILE *outputFile;
  long responseCode = 0;
  long byteCount;
  char *contentType = NULL;

  if (![fileManager fileExistsAtPath:certificatePath]) {
    NSLog(@"CA certificate bundle is missing at %@", certificatePath);
    return NO;
  }
  outputFile = fopen([temporaryPath fileSystemRepresentation], "wb");
  if (outputFile == NULL) {
    NSLog(@"Could not open the network test output file");
    return NO;
  }
  curl = curl_easy_init();
  if (curl == NULL) {
    fclose(outputFile);
    NSLog(@"Could not create a libcurl handle");
    return NO;
  }

  curl_easy_setopt(curl, CURLOPT_URL, kRCNetworkTestURL);
  curl_easy_setopt(curl, CURLOPT_CAINFO,
                   [certificatePath fileSystemRepresentation]);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(curl, CURLOPT_PROTOCOLS, (long)CURLPROTO_HTTPS);
  curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, (long)CURLPROTO_HTTPS);
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 20L);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 120L);
  curl_easy_setopt(curl, CURLOPT_USERAGENT, "RetroCloudSync/0.1");
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, outputFile);

  result = curl_easy_perform(curl);
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &responseCode);
  curl_easy_getinfo(curl, CURLINFO_CONTENT_TYPE, &contentType);
  byteCount = ftell(outputFile);
  fclose(outputFile);

  if (result != CURLE_OK || responseCode != 200 || byteCount <= 0 ||
      contentType == NULL || strncmp(contentType, "image/", 6) != 0) {
    NSLog(@"Network test failed: %s (HTTP %ld, %ld bytes, type %s)",
          curl_easy_strerror(result), responseCode, byteCount,
          contentType == NULL ? "unknown" : contentType);
    curl_easy_cleanup(curl);
    [fileManager removeFileAtPath:temporaryPath handler:nil];
    return NO;
  }
  curl_easy_cleanup(curl);

  if ([fileManager fileExistsAtPath:outputPath] &&
      ![fileManager removeFileAtPath:outputPath handler:nil]) {
    NSLog(@"Could not replace the previous network test download");
    [fileManager removeFileAtPath:temporaryPath handler:nil];
    return NO;
  }
  if (![fileManager movePath:temporaryPath toPath:outputPath handler:nil]) {
    NSLog(@"Could not finish the network test download");
    [fileManager removeFileAtPath:temporaryPath handler:nil];
    return NO;
  }
  NSLog(@"Network test downloaded %ld bytes to %@", byteCount, outputPath);
  return YES;
}

int main(int argc, char *argv[])
{
  NSAutoreleasePool *processPool;
  NSPort *keepAlivePort;
  NSString *daemonPath;
  NSString *daemonDirectory;
  NSString *certificatePath;
  RCMailProxyConfig mailConfigs[2];
  RCMailProxy *mailProxy;

  (void)argc;

  signal(SIGINT, HandleTerminationSignal);
  signal(SIGTERM, HandleTerminationSignal);
  signal(SIGPIPE, SIG_IGN);

  processPool = [[NSAutoreleasePool alloc] init];
  if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
    NSLog(@"Could not initialize AltivecCore libcurl");
    [processPool release];
    return 1;
  }
  if (!DownloadNetworkTest(argv[0])) {
    curl_global_cleanup();
    [processPool release];
    return 1;
  }
  daemonPath = [NSString stringWithUTF8String:argv[0]];
  daemonDirectory = [daemonPath stringByDeletingLastPathComponent];
  certificatePath = [daemonDirectory
      stringByAppendingPathComponent:kRCCertificateName];
  mailConfigs[0].serviceName = "IMAP";
  mailConfigs[0].localPort = kRCIMAPLocalPort;
  mailConfigs[0].remoteHost = kRCIMAPServer;
  mailConfigs[0].remotePort = kRCIMAPServerPort;
  mailConfigs[0].mode = kRCMailProxyImplicitTLS;
  mailConfigs[1].serviceName = "SMTP";
  mailConfigs[1].localPort = kRCSMTPLocalPort;
  mailConfigs[1].remoteHost = kRCSMTPServer;
  mailConfigs[1].remotePort = kRCSMTPServerPort;
  mailConfigs[1].mode = kRCMailProxySMTPStartTLS;
  mailProxy = RCMailProxyStart(mailConfigs, 2,
      [certificatePath fileSystemRepresentation]);
  if (mailProxy == NULL) {
    curl_global_cleanup();
    [processPool release];
    return 1;
  }
  keepAlivePort = [[NSPort port] retain];
  [[NSRunLoop currentRunLoop] addPort:keepAlivePort
                              forMode:NSDefaultRunLoopMode];
  NSLog(@"Hello from Retro Cloud Sync daemon");

  while (gShouldKeepRunning) {
    NSAutoreleasePool *iterationPool;
    NSDate *wakeDate;

    iterationPool = [[NSAutoreleasePool alloc] init];
    wakeDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
    [[NSRunLoop currentRunLoop] runUntilDate:wakeDate];
    [iterationPool release];
  }

  [[NSRunLoop currentRunLoop] removePort:keepAlivePort
                                 forMode:NSDefaultRunLoopMode];
  [keepAlivePort release];
  RCMailProxyStop(mailProxy);

  NSLog(@"Retro Cloud Sync daemon stopped");
  curl_global_cleanup();
  [processPool release];

  return 0;
}
