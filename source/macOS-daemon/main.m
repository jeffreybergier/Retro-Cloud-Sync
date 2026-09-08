#import "RCLogger.h"
//
//  main.m
//  RetroCloudSyncDaemon
//

#import <Foundation/Foundation.h>
#import <AltivecCore/AltivecCore.h>

#include "RCMailProxy.h"
#include "RCCardDAVMirror.h"
#include "RCICloudCredentials.h"
#include "RCSyncServicesBridge.h"
#include "RCCalDAVMirror.h"
#include "RCCalendarSyncServicesBridge.h"
#import "RCTwoWayNative.h"

#include <Security/Security.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static NSString * const kRCCertificateName = @"cacert.pem";
static NSString * const kRCSyncClientDescriptionName = @"SyncClient.plist";

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
  char *syncClientDescriptionPath;
  char *calendarDatabasePath;
  char *calendarDescriptionPath;
  int contactsEnabled;
  int contactsTwoWay;
  int calendarsTwoWay;
  int calendarsEnabled;
  int calendarHistoryYears;
} RCSyncWorker;

static char *RCCopyCString(const char *string)
{
  size_t length;
  char *copy;

  if (string == NULL)
    return NULL;
  length = strlen(string);
  copy = (char *)malloc(length + 1);
  if (copy != NULL)
    memcpy(copy, string, length + 1);
  return copy;
}

static void RCContactProgress(RCLogLevel level, const char *message, void *context)
{
  (void)context;
  if (message != NULL)
    RCLoggerC(level, "Contacts", "Download", "%s", message);
}

static void RCCalendarProgress(RCLogLevel level, const char *message, void *context)
{
  (void)context;
  if (message)
    RCLoggerC(level, "Calendars", "Download", "%s", message);
}

static NSString *RCSyncModeFromConfiguration(NSDictionary *configuration,
                                             NSString *modeKey,
                                             NSString *legacyEnabledKey,
                                             BOOL legacyValueIsRequired)
{
  id mode = [configuration objectForKey:modeKey];
  id enabled;

  if (mode != nil) {
    if ([mode isKindOfClass:[NSString class]] &&
        ([mode isEqualToString:@"Disabled"] || [mode isEqualToString:@"OneWay"] ||
         [mode isEqualToString:@"TwoWay"])) {
      return mode;
    }
    return nil;
  }
  enabled = [configuration objectForKey:legacyEnabledKey];
  if (enabled == nil && !legacyValueIsRequired)
    return @"Disabled";
  if (![enabled isKindOfClass:[NSNumber class]])
    return nil;
  return [enabled boolValue] ? @"OneWay" : @"Disabled";
}

static void RCRunAccountWrites(RCWriteJournal *journal, RCSyncWorker *worker,
                               const char *password, BOOL calendars)
{
  RCHTTPClientConfig config;
  RCError error;
  RCHTTPClient *http;
  if (!password) return;
  memset(&config,0,sizeof(config)); RCErrorClear(&error);
  config.username=worker->username; config.password=password;
  config.certificatePath=worker->certificatePath;
  config.allowedHostSuffix=".icloud.com";
  http=RCHTTPClientCreate(&config,&error);
  if (!http || RCTwoWayRunWrites(journal,http,calendars ? "text/calendar; charset=utf-8" :
      "text/vcard; charset=utf-8",&error)<0)
    RCLogger(RCLogWarning, NULL, "Upload", @"Outgoing pass failed; queued changes remain pending: %s",error.message);
  RCHTTPClientDestroy(http);
}

/* Changing back to one-way must not publish over a still-journaled local edit.
   Disabled mode simply pauses everything, including the outgoing writer. */
static BOOL RCHasPendingWrites(RCWriteJournal *journal)
{
  sqlite3_stmt *query=NULL;
  int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(journal->db,"SELECT 1 FROM write_operations WHERE account_id=? "
      "AND state NOT IN ('acknowledged','cancelled') LIMIT 1",-1,&query,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(query,1,journal->account); step=sqlite3_step(query);
  }
  sqlite3_finalize(query);
  return step!=SQLITE_DONE;
}

static void *RCSyncWorkerMain(void *context)
{
  RCSyncWorker *worker = (RCSyncWorker *)context;
  unsigned long poll = 0;

  /* This per-user LaunchAgent runs in the graphical login session. Keep
     Keychain interaction enabled: on Leopard, disabling it can reject even
     an unlocked item's pre-authorized reader with errSecAuthFailed. */
  for (;;) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    char *password = NULL;
    size_t passwordLength = 0;
    RCContactStore *store = NULL;
    RCCardDAVMirrorConfig mirrorConfig;
    RCCardDAVMirrorResult result;
    RCContactStoreStatistics statistics;
    long syncRecordCount = 0;
    RCError error;
    struct timespec wakeTime;
    int shouldStop;
    BOOL contactsFetched=NO, calendarsFetched=NO;
    NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];

    pthread_mutex_lock(&worker->mutex);
    shouldStop = worker->shouldStop;
    pthread_mutex_unlock(&worker->mutex);
    if (shouldStop) {
      [pool release];
      break;
    }

    RCLoggerSetContext("Account", ++poll);
    RCLogger(RCLogDebug, NULL, "Poll", @"Starting poll");
    RCErrorClear(&error);
    if (!RCICloudCredentialsCopyPassword(worker->username, &password, &passwordLength,
                                         &error)) {
      RCLogger(RCLogWarning, "Account", "Credentials", @"Downloads and uploads skipped; saved password unavailable: %s", error.message);
    }
    if (worker->contactsEnabled) {
      RCLoggerSetContext("Contacts", poll);
      RCErrorClear(&error);
      store = RCContactStoreOpen(worker->databasePath, worker->username, &error);
      if (store == NULL) {
        RCLogger(RCLogError, "Contacts", "Database", @"Could not open database; Contacts skipped this poll: %s", error.message);
      } else {
        RCWriteJournal journal=RCContactStoreWriteJournal(store);
        if (worker->contactsTwoWay) RCRunAccountWrites(&journal,worker,password,NO);
        memset(&mirrorConfig, 0, sizeof(mirrorConfig));
        mirrorConfig.serviceURL = worker->serviceURL;
        mirrorConfig.username = worker->username;
        mirrorConfig.password = password;
        mirrorConfig.certificatePath = worker->certificatePath;
        mirrorConfig.allowedHostSuffix = ".icloud.com";
        mirrorConfig.progress = RCContactProgress;
        if (password != NULL) {
          if ((contactsFetched=RCCardDAVMirrorFetch(&mirrorConfig, store, &result, &error)) &&
              RCContactStoreGetStatistics(store, &statistics, &error)) {
            RCLogger(RCLogInfo, "Contacts", "Download", @"Download complete: %ld resources downloaded, %ld unchanged this poll; "
                  @"stored totals: %ld available, %ld remotely absent, %ld invalid resources",
                  result.downloadedResourceCount, result.unchangedResourceCount,
                  statistics.availableCount, statistics.missingCount,
                  statistics.parseErrorCount);
          } else {
            RCLogger(RCLogError, "Contacts", "Download", @"%s failed: %s", contactsFetched ? "Reading download statistics" : "Download", error.message);
          }
        }
        /* A failed fetch (or locked Keychain) must not prevent retrying the
           last committed mirror. The bridge refuses a never-completed mirror. */
        RCErrorClear(&error);
        BOOL exported;
        if (worker->contactsTwoWay) {
          exported=contactsFetched && RCSyncServicesTwoWayContacts(store,
              worker->syncClientDescriptionPath,&syncRecordCount,&error);
          if (!contactsFetched) RCErrorSet(&error,1,"Skipped: two-way local application requires a successful download");
          if (exported) RCRunAccountWrites(&journal,worker,password,NO);
        } else if (RCHasPendingWrites(&journal)) {
          exported=NO; RCErrorSet(&error,1,"Pending outgoing changes must be resolved before one-way publication");
        } else {
          if (!contactsFetched) RCLogger(RCLogInfo, "Contacts", "Apply", @"Attempting local application from the last committed download");
          exported=RCSyncServicesPushContacts(store,worker->syncClientDescriptionPath,&syncRecordCount,&error);
        }
        if (exported && syncRecordCount<0) {
          RCLogger(RCLogWarning, "Contacts", "Apply", @"Applied eligible records to local apps; unresolved local edits remain pending");
        } else if (exported) {
          RCLogger(RCLogInfo, "Contacts", "Apply", @"Local application complete: %ld Sync Services records in snapshot", syncRecordCount);
        } else if (worker->contactsTwoWay && !contactsFetched) {
          RCLogger(RCLogWarning, "Contacts", "Apply", @"Skipped: two-way local application requires a successful download");
        } else {
          RCLogger(RCLogError, "Contacts", "Apply", @"Local application failed: %s", error.message);
        }
      }
    }
    RCContactStoreClose(store);
    if (worker->calendarsEnabled) {
      RCCalendarStore *calendarStore;
      RCLoggerSetContext("Calendars", poll);
      RCErrorClear(&error);
      calendarStore =
          RCCalendarStoreOpen(worker->calendarDatabasePath, worker->username, &error);
      if (calendarStore == NULL)
        RCLogger(RCLogError, "Calendars", "Database", @"Could not open database; Calendars skipped this poll: %s", error.message);
      else {
        RCWriteJournal journal=RCCalendarStoreWriteJournal(calendarStore);
        if (worker->calendarsTwoWay) RCRunAccountWrites(&journal,worker,password,YES);
        memset(&mirrorConfig, 0, sizeof(mirrorConfig));
        mirrorConfig.serviceURL = "https://caldav.icloud.com";
        mirrorConfig.username = worker->username;
        mirrorConfig.password = password;
        mirrorConfig.certificatePath = worker->certificatePath;
        mirrorConfig.allowedHostSuffix = ".icloud.com";
        mirrorConfig.progress = RCCalendarProgress;
        if (password != NULL) {
          char historyStart[17];
          const char *today = [[[NSDate date] descriptionWithCalendarFormat:@"%Y%m%d"
              timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0] locale:nil] UTF8String];
          if ((worker->calendarHistoryYears == 0 ||
               RCCalDAVHistoryStart(today, worker->calendarHistoryYears, historyStart, &error)) &&
              (calendarsFetched=RCCalDAVMirrorFetchSince(&mirrorConfig, calendarStore,
                  worker->calendarHistoryYears ? historyStart : NULL, &result, &error)))
            RCLogger(RCLogInfo, "Calendars", "Download", @"Download complete: %ld calendars, %ld resources downloaded, %ld "
                  @"resources unchanged this poll",
                  result.collectionCount, result.downloadedResourceCount,
                  result.unchangedResourceCount);
          else
            RCLogger(RCLogError, "Calendars", "Download", @"Download failed: %s", error.message);
        }
        RCErrorClear(&error);
        BOOL exported;
        if (worker->calendarsTwoWay) {
          exported=calendarsFetched && RCSyncServicesTwoWayCalendars(calendarStore,
              worker->calendarDescriptionPath,&syncRecordCount,&error);
          if (!calendarsFetched) RCErrorSet(&error,1,"Skipped: two-way local application requires a successful download");
          if (exported) RCRunAccountWrites(&journal,worker,password,YES);
        } else if (RCHasPendingWrites(&journal)) {
          exported=NO; RCErrorSet(&error,1,"Pending outgoing changes must be resolved before one-way publication");
        } else {
          if (!calendarsFetched) RCLogger(RCLogInfo, "Calendars", "Apply", @"Attempting local application from the last committed download");
          exported=RCSyncServicesPushCalendars(calendarStore,worker->calendarDescriptionPath,0,&syncRecordCount,&error);
        }
        if (exported && syncRecordCount<0) {
          RCLogger(RCLogWarning, "Calendars", "Apply", @"Applied eligible records to local apps; unresolved local edits remain pending");
        } else if (exported) {
          RCLogger(RCLogInfo, "Calendars", "Apply", @"Local application complete: %ld Sync Services records in snapshot",
                syncRecordCount);
          if (!RCCalendarStorePruneHistory(calendarStore, &error))
            RCLogger(RCLogError, "Calendars", "Database", @"Calendar history cleanup failed: %s", error.message);
        } else if (worker->calendarsTwoWay && !calendarsFetched)
          RCLogger(RCLogWarning, "Calendars", "Apply", @"Skipped: two-way local application requires a successful download");
        else
          RCLogger(RCLogError, "Calendars", "Apply", @"Local application failed: %s", error.message);
        RCCalendarStoreClose(calendarStore);
      }
    }
    RCLoggerSetContext("Account", poll);
    RCLogger(RCLogInfo, NULL, "Poll", @"Finished in %.1fs; next poll in %us",
        [NSDate timeIntervalSinceReferenceDate] - started, worker->interval);
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
    if (shouldStop)
      break;
  }
  return NULL;
}

static BOOL RCSyncWorkerStart(RCSyncWorker *worker, NSDictionary *configuration,
                              NSString *daemonDirectory)
{
  NSDictionary *contacts = [configuration objectForKey:@"Contacts"];
  NSString *username;
  NSString *serviceURL;
  NSNumber *interval;
  id historyYears;
  NSString *contactsSyncMode;
  NSString *calendarsSyncMode;
  NSString *databasePath;
  NSString *certificatePath;
  NSString *syncClientDescriptionPath;

  memset(worker, 0, sizeof(*worker));
  if (contacts == nil) {
    RCLogger(RCLogInfo, "Contacts", "Startup", @"Sync is disabled");
    RCLogger(RCLogInfo, "Calendars", "Startup", @"Sync is disabled");
    return YES;
  }
  if (![contacts isKindOfClass:[NSDictionary class]])
    { RCLogger(RCLogError, "Account", "Startup", @"Contacts configuration must be a dictionary; daemon cannot start"); return NO; }
  contactsSyncMode =
      RCSyncModeFromConfiguration(contacts, @"ContactsSyncMode", @"Enabled", YES);
  calendarsSyncMode = RCSyncModeFromConfiguration(contacts, @"CalendarsSyncMode",
                                                  @"CalendarsEnabled", NO);
  if (contactsSyncMode == nil || calendarsSyncMode == nil) {
    RCLogger(RCLogError, "Account", "Startup", @"Contacts and Calendars sync mode configuration is invalid");
    return NO;
  }
  worker->contactsTwoWay = [contactsSyncMode isEqualToString:@"TwoWay"];
  worker->calendarsTwoWay = [calendarsSyncMode isEqualToString:@"TwoWay"];
  worker->contactsEnabled = worker->contactsTwoWay || [contactsSyncMode isEqualToString:@"OneWay"];
  worker->calendarsEnabled = worker->calendarsTwoWay || [calendarsSyncMode isEqualToString:@"OneWay"];
  historyYears = [contacts objectForKey:@"CalendarHistoryYears"];
  worker->calendarHistoryYears = historyYears == nil ? 2 :
      ([historyYears isKindOfClass:[NSNumber class]] ? [historyYears intValue] : -1);
  if (worker->calendarHistoryYears < 0 || worker->calendarHistoryYears > 2 ||
      (historyYears != nil && [historyYears isKindOfClass:[NSNumber class]] &&
       [historyYears doubleValue] != worker->calendarHistoryYears)) {
    RCLogger(RCLogError, "Calendars", "Startup", @"Calendar history must be 0 (all history), 1, or 2 years");
    return NO;
  }

  if (!worker->contactsEnabled)
    RCLogger(RCLogInfo, "Contacts", "Startup", @"Sync is disabled");
  if (!worker->calendarsEnabled)
    RCLogger(RCLogInfo, "Calendars", "Startup", @"Sync is disabled");
  if (!worker->contactsEnabled && !worker->calendarsEnabled)
    return YES;
  username = [contacts objectForKey:@"Username"];
  serviceURL = [contacts objectForKey:@"ServiceURL"];
  interval = [contacts objectForKey:@"SyncIntervalSeconds"];
  if (![username isKindOfClass:[NSString class]] || [username length] == 0 ||
      ![serviceURL isKindOfClass:[NSString class]] ||
      ![serviceURL isEqualToString:@"https://contacts.icloud.com"] ||
      ![interval isKindOfClass:[NSNumber class]] || [interval unsignedIntValue] < 60 ||
      [interval unsignedIntValue] > 604800 || [username UTF8String] == NULL ||
      [serviceURL UTF8String] == NULL) {
    RCLogger(RCLogError, "Account", "Startup", @"Account configuration is invalid; daemon cannot start");
    return NO;
  }
  databasePath = [daemonDirectory stringByAppendingPathComponent:@"Contacts.sqlite"];
  certificatePath = [daemonDirectory stringByAppendingPathComponent:kRCCertificateName];
  syncClientDescriptionPath =
      [daemonDirectory stringByAppendingPathComponent:kRCSyncClientDescriptionName];
  worker->username = RCCopyCString([username UTF8String]);
  worker->serviceURL = RCCopyCString([serviceURL UTF8String]);
  worker->databasePath = RCCopyCString([databasePath fileSystemRepresentation]);
  worker->certificatePath = RCCopyCString([certificatePath fileSystemRepresentation]);
  worker->syncClientDescriptionPath =
      RCCopyCString([syncClientDescriptionPath fileSystemRepresentation]);
  worker->calendarDatabasePath = RCCopyCString([[daemonDirectory
      stringByAppendingPathComponent:@"Calendar.sqlite"] fileSystemRepresentation]);
  worker->calendarDescriptionPath = RCCopyCString(
      [[daemonDirectory stringByAppendingPathComponent:@"CalendarSyncClient.plist"]
          fileSystemRepresentation]);
  set_zone_directory([[daemonDirectory stringByAppendingPathComponent:@"zoneinfo"]
      fileSystemRepresentation]);
  worker->interval = [interval unsignedIntValue];
  RCLogger(RCLogInfo, "Account", "Startup",
      @"Contacts=%@, Calendars=%@, interval=%us, calendar history=%@",
      contactsSyncMode, calendarsSyncMode, worker->interval,
      worker->calendarHistoryYears ? [NSString stringWithFormat:@"%d years", worker->calendarHistoryYears] : @"all");
  if (worker->username == NULL || worker->serviceURL == NULL ||
      worker->databasePath == NULL || worker->certificatePath == NULL ||
      worker->syncClientDescriptionPath == NULL ||
      worker->calendarDatabasePath == NULL || worker->calendarDescriptionPath == NULL) {
    RCLogger(RCLogError, "Daemon", "Startup", @"Could not allocate sync worker configuration");
    goto failed;
  }
  pthread_mutex_init(&worker->mutex, NULL);
  pthread_cond_init(&worker->condition, NULL);
  if (pthread_create(&worker->thread, NULL, RCSyncWorkerMain, worker) != 0) {
    RCLogger(RCLogError, "Daemon", "Startup", @"Could not start the account sync worker");
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
  free(worker->syncClientDescriptionPath);
  free(worker->calendarDatabasePath);
  free(worker->calendarDescriptionPath);
  memset(worker, 0, sizeof(*worker));
  return NO;
}

static void RCSyncWorkerStop(RCSyncWorker *worker)
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
  free(worker->syncClientDescriptionPath);
  free(worker->calendarDatabasePath);
  free(worker->calendarDescriptionPath);
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
    RCLogger(RCLogError, "Mail", "Startup", @"%@ mail proxy settings are missing", serviceKey);
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
    RCLogger(RCLogError, "Mail", "Startup", @"%@ mail proxy settings are invalid", serviceKey);
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
    RCLogger(RCLogError, "Mail", "Startup", @"Could not read mail proxy configuration at %@", path);
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
    RCLogger(RCLogError, "Daemon", "Startup", @"Mail proxy configuration is invalid");
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
  RCSyncWorker syncWorker;

  signal(SIGINT, HandleTerminationSignal);
  signal(SIGTERM, HandleTerminationSignal);
  signal(SIGPIPE, SIG_IGN);

  processPool = [[NSAutoreleasePool alloc] init];
  memset(&syncWorker, 0, sizeof(syncWorker));
  if ((argc == 4 && strcmp(argv[1], "--export-recovery") == 0) ||
      (argc == 3 && strcmp(argv[1], "--inspect-recovery") == 0)) {
    sqlite3 *database=NULL;
    sqlite3_stmt *statement=NULL;
    RCError error;
    int ok=0;
    RCErrorClear(&error);
    if (sqlite3_open_v2(argv[2],&database,SQLITE_OPEN_READONLY,NULL)!=SQLITE_OK) {
      RCErrorSet(&error,1,"Could not open recovery database read-only");
    } else if (argc==4) {
      ok=RCWriteJournalBackup(database,argv[3],&error);
      if (ok) printf("Recovery snapshot exported.\n");
    } else if (sqlite3_prepare_v2(database,
        "SELECT o.id,o.kind,o.state,COALESCE(a.reason,'') FROM write_operations o "
        "LEFT JOIN write_attention a ON a.operation_id=o.id "
        "WHERE o.state NOT IN ('acknowledged','cancelled') ORDER BY o.id",
        -1,&statement,NULL)==SQLITE_OK) {
      int step;
      puts("Operation Kind State Attention");
      while ((step=sqlite3_step(statement))==SQLITE_ROW)
        printf("%lld %s %s %s\n",sqlite3_column_int64(statement,0),
            sqlite3_column_text(statement,1),sqlite3_column_text(statement,2),
            sqlite3_column_text(statement,3));
      ok=step==SQLITE_DONE;
      if (!ok) RCErrorSet(&error,1,"Could not inspect recovery operations");
      sqlite3_finalize(statement); statement=NULL;
      if (ok && sqlite3_prepare_v2(database,"SELECT reason,count(*) FROM two_way_attention GROUP BY reason",
          -1,&statement,NULL)==SQLITE_OK) {
        puts("Deferred native changes (reason/count)");
        while ((step=sqlite3_step(statement))==SQLITE_ROW)
          printf("%s %d\n",sqlite3_column_text(statement,0),sqlite3_column_int(statement,1));
        if (step!=SQLITE_DONE) { ok=0; RCErrorSet(&error,1,"Could not inspect native attention state"); }
      }
    } else RCErrorSet(&error,1,"Database has no current recovery journal");
    sqlite3_finalize(statement);
    if (database) sqlite3_close(database);
    if (!ok) fprintf(stderr,"%s\n",error.message);
    [processPool release]; return ok ? 0 : 1;
  }
  if (argc == 4 && strcmp(argv[1], "--test-calendar-syncservices") == 0) {
    RCError error;
    RCCalendarStore *store=RCCalendarStoreOpen(argv[2],"calendar-test",&error);
    long count=0;
    int ok=store && RCSyncServicesPushCalendars(store,argv[3],1,&count,&error);
    if (ok) RCLogger(RCLogInfo, "Calendars", "Test", @"Calendar test export complete: %ld records",count);
    else RCLogger(RCLogError, "Calendars", "Test", @"Calendar test export failed: %s",error.message);
    RCCalendarStoreClose(store); [processPool release]; return ok?0:1;
  }
  if (argc == 2 && strcmp(argv[1], "--unregister-calendar-test-client") == 0) {
    RCError error; int ok=RCSyncServicesUnregisterCalendarTestClient(&error);
    if (!ok) RCLogger(RCLogError, "Calendars", "Test", @"Calendar test cleanup failed: %s",error.message);
    [processPool release]; return ok?0:1;
  }
  if (argc == 4 && strcmp(argv[1], "--test-syncservices") == 0) {
    RCContactStore *store;
    RCError error;
    long recordCount = 0;
    int status;

    RCErrorClear(&error);
    store = RCContactStoreOpen(argv[2], "syncservices-test", &error);
    status = store != NULL && RCSyncServicesPushTestContacts(
        store, argv[3], &recordCount, &error);
    if (status) {
      RCLogger(RCLogInfo, "Contacts", "Apply", @"Local application complete: %ld Sync Services records in snapshot", recordCount);
    } else {
      RCLogger(RCLogError, "Contacts", "Apply", @"Local application failed: %s", error.message);
    }
    RCContactStoreClose(store);
    [processPool release];
    return status ? 0 : 1;
  }
  if (argc == 2 &&
      strcmp(argv[1], "--unregister-syncservices-test-client") == 0) {
    RCError error;
    int status;

    RCErrorClear(&error);
    status = RCSyncServicesUnregisterTestClient(&error);
    if (!status) {
      RCLogger(RCLogError, "Daemon", "Test", @"Could not unregister Sync Services test client: %s",
            error.message);
    }
    [processPool release];
    return status ? 0 : 1;
  }
  if (argc == 3 && strcmp(argv[1], "--config") == 0) {
    configurationPath = [NSString stringWithUTF8String:argv[2]];
    if (configurationPath == nil) {
      RCLogger(RCLogError, "Daemon", "Startup", @"The configuration path is not valid UTF-8");
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
    RCLogger(RCLogError, "Daemon", "Startup", @"Usage: RetroCloudSyncDaemon [--config path] | "
           "--inspect-recovery database | --export-recovery database new-snapshot | "
           "--test-syncservices database client-description | "
           "--unregister-syncservices-test-client");
    [processPool release];
    return 1;
  }
  if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
    RCLogger(RCLogError, "Daemon", "Startup", @"Could not initialize AltivecCore libcurl");
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
    if (!RCSyncWorkerStart(&syncWorker, configuration, daemonDirectory)) {
      RCLogger(RCLogError, "Daemon", "Startup", @"Account worker initialization failed; daemon exiting");
      RCMailProxyStop(mailProxy);
      curl_global_cleanup();
      [configuration release];
      [processPool release];
      return 1;
    }
  }
  keepAlivePort = [[NSPort port] retain];
  [[NSRunLoop currentRunLoop] addPort:keepAlivePort
                              forMode:NSDefaultRunLoopMode];
  RCLogger(RCLogInfo, "Daemon", "Startup", @"Ready");

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
  RCLogger(RCLogInfo, "Daemon", "Shutdown", @"Stop requested; waiting for active work");
  RCSyncWorkerStop(&syncWorker);
  RCMailProxyStop(mailProxy);

  RCLogger(RCLogInfo, "Daemon", "Shutdown", @"Stopped");
  curl_global_cleanup();
  [configuration release];
  [processPool release];

  return 0;
}
