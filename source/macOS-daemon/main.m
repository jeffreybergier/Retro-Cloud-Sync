//
//  main.m
//  RetroCloudSyncDaemon
//

#import <Foundation/Foundation.h>
#import <AltivecCore/AltivecCore.h>

#include "RCMailProxy.h"
#include "RCCardDAVMirror.h"
#include "RCICloudCredentials.h"

#include <Security/Security.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

typedef struct {
  pthread_t thread;
  pthread_mutex_t mutex;
  pthread_cond_t condition;
  int started;
  int shouldStop;
  unsigned int interval;
  char *username;
  char *serviceURL;
  char *databasePath;
  char *certificatePath;
} RCContactWorker;

static char *RCCopyCString(const char *string)
{
  size_t length;
  char *copy;

  if (string == NULL) return NULL;
  length = strlen(string);
  copy = (char *)malloc(length + 1);
  if (copy != NULL) memcpy(copy, string, length + 1);
  return copy;
}

static void RCContactProgress(const char *message, void *context)
{
  (void)context;
  if (message != NULL) NSLog(@"Contacts: %s", message);
}

static void *RCContactWorkerMain(void *context)
{
  RCContactWorker *worker = (RCContactWorker *)context;

  SecKeychainSetUserInteractionAllowed(0);
  for (;;) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    char *password = NULL;
    size_t passwordLength = 0;
    RCContactStore *store = NULL;
    RCCardDAVMirrorConfig mirrorConfig;
    RCCardDAVMirrorResult result;
    RCContactStoreStatistics statistics;
    RCError error;
    struct timespec wakeTime;
    int shouldStop;

    pthread_mutex_lock(&worker->mutex);
    shouldStop = worker->shouldStop;
    pthread_mutex_unlock(&worker->mutex);
    if (shouldStop) {
      [pool release];
      break;
    }

    RCErrorClear(&error);
    if (!RCICloudCredentialsCopyPassword(worker->username, &password,
                                         &passwordLength, &error)) {
      NSLog(@"Contacts sync skipped: %s", error.message);
    } else if ((store = RCContactStoreOpen(worker->databasePath, &error)) ==
               NULL) {
      NSLog(@"Contacts sync failed: %s", error.message);
    } else {
      memset(&mirrorConfig, 0, sizeof(mirrorConfig));
      mirrorConfig.serviceURL = worker->serviceURL;
      mirrorConfig.username = worker->username;
      mirrorConfig.password = password;
      mirrorConfig.certificatePath = worker->certificatePath;
      mirrorConfig.allowedHostSuffix = ".icloud.com";
      mirrorConfig.progress = RCContactProgress;
      if (RCCardDAVMirrorFetch(&mirrorConfig, store, &result, &error) &&
          RCContactStoreGetStatistics(store, &statistics, &error)) {
        NSLog(@"Contacts sync complete: %ld downloaded, %ld unchanged, "
              @"%ld available, %ld remotely absent",
              result.downloadedResourceCount, result.unchangedResourceCount,
              statistics.availableCount, statistics.missingCount);
      } else {
        NSLog(@"Contacts sync failed: %s", error.message);
      }
    }
    RCContactStoreClose(store);
    RCICloudCredentialsClearPassword(password, passwordLength);
    [pool release];

    wakeTime.tv_sec = time(NULL) + worker->interval;
    wakeTime.tv_nsec = 0;
    pthread_mutex_lock(&worker->mutex);
    if (!worker->shouldStop) {
      pthread_cond_timedwait(&worker->condition, &worker->mutex, &wakeTime);
    }
    shouldStop = worker->shouldStop;
    pthread_mutex_unlock(&worker->mutex);
    if (shouldStop) break;
  }
  return NULL;
}

static BOOL RCContactWorkerStart(RCContactWorker *worker,
                                 NSDictionary *configuration,
                                 NSString *daemonDirectory)
{
  NSDictionary *contacts = [configuration objectForKey:@"Contacts"];
  NSString *username;
  NSString *serviceURL;
  NSNumber *interval;
  NSNumber *enabled;
  NSString *databasePath;
  NSString *certificatePath;

  memset(worker, 0, sizeof(*worker));
  if (contacts == nil) {
    return YES;
  }
  if (![contacts isKindOfClass:[NSDictionary class]]) return NO;
  enabled = [contacts objectForKey:@"Enabled"];
  if (![enabled isKindOfClass:[NSNumber class]]) return NO;
  if (![enabled boolValue]) return YES;
  username = [contacts objectForKey:@"Username"];
  serviceURL = [contacts objectForKey:@"ServiceURL"];
  interval = [contacts objectForKey:@"SyncIntervalSeconds"];
  if (![username isKindOfClass:[NSString class]] || [username length] == 0 ||
      ![serviceURL isKindOfClass:[NSString class]] ||
      ![serviceURL isEqualToString:@"https://contacts.icloud.com"] ||
      ![interval isKindOfClass:[NSNumber class]] ||
      [interval unsignedIntValue] < 60 ||
      [interval unsignedIntValue] > 604800 ||
      [username UTF8String] == NULL ||
      [serviceURL UTF8String] == NULL) {
    NSLog(@"Contacts configuration is invalid; contact sync is disabled");
    return NO;
  }
  databasePath = [daemonDirectory stringByAppendingPathComponent:
      @"Contacts.sqlite"];
  certificatePath = [daemonDirectory stringByAppendingPathComponent:
      kRCCertificateName];
  worker->username = RCCopyCString([username UTF8String]);
  worker->serviceURL = RCCopyCString([serviceURL UTF8String]);
  worker->databasePath = RCCopyCString([databasePath fileSystemRepresentation]);
  worker->certificatePath = RCCopyCString(
      [certificatePath fileSystemRepresentation]);
  worker->interval = [interval unsignedIntValue];
  if (worker->username == NULL || worker->serviceURL == NULL ||
      worker->databasePath == NULL || worker->certificatePath == NULL) {
    NSLog(@"Could not allocate contact worker configuration");
    goto failed;
  }
  pthread_mutex_init(&worker->mutex, NULL);
  pthread_cond_init(&worker->condition, NULL);
  if (pthread_create(&worker->thread, NULL, RCContactWorkerMain, worker) != 0) {
    NSLog(@"Could not start the contact sync worker");
    pthread_cond_destroy(&worker->condition);
    pthread_mutex_destroy(&worker->mutex);
    goto failed;
  }
  worker->started = 1;
  return YES;

failed:
  free(worker->username);
  free(worker->serviceURL);
  free(worker->databasePath);
  free(worker->certificatePath);
  memset(worker, 0, sizeof(*worker));
  return NO;
}

static void RCContactWorkerStop(RCContactWorker *worker)
{
  if (worker->started) {
    pthread_mutex_lock(&worker->mutex);
    worker->shouldStop = 1;
    pthread_cond_signal(&worker->condition);
    pthread_mutex_unlock(&worker->mutex);
    pthread_join(worker->thread, NULL);
    pthread_cond_destroy(&worker->condition);
    pthread_mutex_destroy(&worker->mutex);
  }
  free(worker->username);
  free(worker->serviceURL);
  free(worker->databasePath);
  free(worker->certificatePath);
  memset(worker, 0, sizeof(*worker));
}

static void HandleTerminationSignal(int signalNumber)
{
  (void)signalNumber;
  gShouldKeepRunning = 0;
}

static BOOL RCLoadServiceConfiguration(NSDictionary *mailProxy,
                                       NSString *serviceKey,
                                       const char *serviceName,
                                       RCMailProxyMode mode,
                                       RCMailProxyConfig *config)
{
  NSDictionary *service = [mailProxy objectForKey:serviceKey];
  NSNumber *localPort;
  NSNumber *remotePort;
  NSString *remoteHost;
  NSCharacterSet *invalidHostCharacters =
      [NSCharacterSet characterSetWithCharactersInString:@" /:\\"];

  if (![service isKindOfClass:[NSDictionary class]]) {
    NSLog(@"%@ mail proxy settings are missing", serviceKey);
    return NO;
  }
  localPort = [service objectForKey:@"LocalPort"];
  remotePort = [service objectForKey:@"RemotePort"];
  remoteHost = [service objectForKey:@"RemoteHost"];
  if (![localPort isKindOfClass:[NSNumber class]] ||
      [localPort intValue] < 1024 || [localPort intValue] > 65535 ||
      ![remotePort isKindOfClass:[NSNumber class]] ||
      [remotePort intValue] < 1 || [remotePort intValue] > 65535 ||
      ![remoteHost isKindOfClass:[NSString class]] ||
      [remoteHost length] == 0 ||
      [remoteHost rangeOfCharacterFromSet:invalidHostCharacters].location !=
          NSNotFound ||
      [remoteHost rangeOfCharacterFromSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]].location !=
          NSNotFound ||
      [remoteHost UTF8String] == NULL) {
    NSLog(@"%@ mail proxy settings are invalid", serviceKey);
    return NO;
  }
  config->serviceName = serviceName;
  config->localPort = (unsigned short)[localPort intValue];
  config->remoteHost = [remoteHost UTF8String];
  config->remotePort = (unsigned short)[remotePort intValue];
  config->mode = mode;
  return YES;
}

static NSDictionary *RCLoadMailConfiguration(NSString *path,
                                               RCMailProxyConfig *configs)
{
  NSDictionary *configuration =
      [[NSDictionary alloc] initWithContentsOfFile:path];
  NSNumber *version;
  NSDictionary *mailProxy;

  if (configuration == nil) {
    NSLog(@"Could not read mail proxy configuration at %@", path);
    return nil;
  }
  version = [configuration objectForKey:@"ConfigurationVersion"];
  mailProxy = [configuration objectForKey:@"MailProxy"];
  if (![version isKindOfClass:[NSNumber class]] || [version intValue] != 1 ||
      ![mailProxy isKindOfClass:[NSDictionary class]] ||
      !RCLoadServiceConfiguration(mailProxy, @"IMAP", "IMAP",
                                  kRCMailProxyImplicitTLS, &configs[0]) ||
      !RCLoadServiceConfiguration(mailProxy, @"SMTP", "SMTP",
                                  kRCMailProxySMTPStartTLS, &configs[1]) ||
      configs[0].localPort == configs[1].localPort) {
    NSLog(@"Mail proxy configuration is invalid");
    [configuration release];
    return nil;
  }
  return configuration;
}

static void RCUseDefaultMailConfiguration(RCMailProxyConfig *configs)
{
  configs[0].serviceName = "IMAP";
  configs[0].localPort = kRCIMAPLocalPort;
  configs[0].remoteHost = kRCIMAPServer;
  configs[0].remotePort = kRCIMAPServerPort;
  configs[0].mode = kRCMailProxyImplicitTLS;
  configs[1].serviceName = "SMTP";
  configs[1].localPort = kRCSMTPLocalPort;
  configs[1].remoteHost = kRCSMTPServer;
  configs[1].remotePort = kRCSMTPServerPort;
  configs[1].mode = kRCMailProxySMTPStartTLS;
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
  NSString *configurationPath = nil;
  NSDictionary *configuration = nil;
  RCMailProxyConfig mailConfigs[2];
  RCMailProxy *mailProxy;
  RCContactWorker contactWorker;

  signal(SIGINT, HandleTerminationSignal);
  signal(SIGTERM, HandleTerminationSignal);
  signal(SIGPIPE, SIG_IGN);

  processPool = [[NSAutoreleasePool alloc] init];
  memset(&contactWorker, 0, sizeof(contactWorker));
  if (argc == 3 && strcmp(argv[1], "--config") == 0) {
    configurationPath = [NSString stringWithUTF8String:argv[2]];
    if (configurationPath == nil) {
      NSLog(@"The configuration path is not valid UTF-8");
      [processPool release];
      return 1;
    }
    configuration = RCLoadMailConfiguration(configurationPath, mailConfigs);
    if (configuration == nil) {
      [processPool release];
      return 1;
    }
  } else if (argc == 1) {
    RCUseDefaultMailConfiguration(mailConfigs);
  } else {
    NSLog(@"Usage: RetroCloudSyncDaemon [--config path]");
    [processPool release];
    return 1;
  }
  if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
    NSLog(@"Could not initialize AltivecCore libcurl");
    [configuration release];
    [processPool release];
    return 1;
  }
  if (!DownloadNetworkTest(argv[0])) {
    curl_global_cleanup();
    [configuration release];
    [processPool release];
    return 1;
  }
  daemonPath = [NSString stringWithUTF8String:argv[0]];
  daemonDirectory = [daemonPath stringByDeletingLastPathComponent];
  certificatePath = [daemonDirectory
      stringByAppendingPathComponent:kRCCertificateName];
  mailProxy = RCMailProxyStart(mailConfigs, 2,
      [certificatePath fileSystemRepresentation]);
  if (mailProxy == NULL) {
    curl_global_cleanup();
    [configuration release];
    [processPool release];
    return 1;
  }
  if (configuration != nil) {
    RCContactWorkerStart(&contactWorker, configuration, daemonDirectory);
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
  RCContactWorkerStop(&contactWorker);
  RCMailProxyStop(mailProxy);

  NSLog(@"Retro Cloud Sync daemon stopped");
  curl_global_cleanup();
  [configuration release];
  [processPool release];

  return 0;
}
