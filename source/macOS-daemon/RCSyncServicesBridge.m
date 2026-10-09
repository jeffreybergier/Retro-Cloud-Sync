#import "RCContactGraph.h"
#import "RCAutorelease.h"
#import "RCSyncConflictSession.h"
#import "RCTwoWayNative.h"
#import "RCContactPhoto.h"
#import "RCLogger.h"
#import "RCSyncServicesBridge.h"
#import "RCContactSyncClient.h"
#import "RCTwoWaySync.h"

#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>

#include "RCVCard.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static NSString * const kRCContactEntity = @"com.apple.contacts.Contact";
static NSString * const kRCPhoneEntity = @"com.apple.contacts.Phone Number";
static NSString * const kRCEmailEntity = @"com.apple.contacts.Email Address";
static NSString * const kRCAddressEntity = @"com.apple.contacts.Street Address";
static NSString * const kRCURLEntity = @"com.apple.contacts.URL";
static NSString * const kRCDateEntity = @"com.apple.contacts.Date";
static NSString * const kRCGroupEntity = @"com.apple.contacts.Group";
static NSString * const kRCSmartGroupEntity = @"com.apple.contacts.SmartGroup";
static NSString * const kRCIMEntity = @"com.apple.contacts.IM";
static NSString * const kRCRelatedNameEntity = @"com.apple.contacts.Related Name";
static NSString * const kRCTestClientIdentifier =
    @"com.altivecintelligence.contacts.test.v1";

static NSString *RCString(const char *value)
{
  NSString *string;
  if (value == NULL || value[0] == '\0') return nil;
  string = [NSString stringWithUTF8String:value];
  if (string == nil) {
    string = [[[NSString alloc] initWithBytes:value length:strlen(value)
                                     encoding:NSISOLatin1StringEncoding]
        autorelease];
  }
  return string;
}

static int RCSyncServicesPushContactsForClient(
    RCContactStore *store, const char *clientDescriptionPath,
    NSString *clientIdentifier, long *recordCount, RCError *error)
{
  NSArray *entities = [NSArray arrayWithObjects:kRCContactEntity, kRCDateEntity,
      kRCEmailEntity, kRCGroupEntity, kRCSmartGroupEntity, kRCIMEntity,
      kRCPhoneEntity, kRCRelatedNameEntity, kRCAddressEntity, kRCURLEntity, nil];
  NSMutableArray *pullEntities = [NSMutableArray array];
  NSString *descriptionPath = RCString(clientDescriptionPath);
  ISyncManager *manager;
  ISyncClient *client;
  ISyncSession *session = nil;
  NSMutableDictionary *records=nil;
  long mappedCount=0;
  long long generation, publishedGeneration;
  int success = 0;

  RCErrorClear(error);
  if (recordCount != NULL) *recordCount = 0;
  if (store == NULL || descriptionPath == nil) {
    RCErrorSet(error, 1, "Sync Services configuration is incomplete");
    return 0;
  }
  @try {
    if (!RCContactStoreGetPublicationState(store, &generation,
                                           &publishedGeneration, error)) return 0;
    if (generation == 0) {
      RCErrorSet(error, 1, "Contact mirror has no complete inventory yet");
      return 0;
    }
    /* Assemble the complete graph before touching Sync Services. A corrupt
       cached body or missing child identity must not publish a partial graph.
       Stable IDs and the unacknowledged generation make interrupted sessions
       replayable, including when the next network attempt fails. */
    records=RCContactPublicationGraph(store,&mappedCount,error);
    if(!records) return 0;
    RCWriteJournal journal=RCContactStoreWriteJournal(store);
    NSDictionary *aliased=RCTwoWayApplyAliases(&journal,records,error);
    if (!aliased) return 0;
    [records setDictionary:aliased];
    manager = [ISyncManager sharedManager];
    if (![manager isEnabled]) {
      NSError *reason = [manager respondsToSelector:@selector(syncDisabledReason)]
          ? [manager performSelector:@selector(syncDisabledReason)] : nil;
      if (reason != nil)
        RCErrorSet(error, 1, "Sync Services is disabled or unavailable (reason %ld)",
                   (long)[reason code]);
      else RCErrorSet(error, 1, "Sync Services is disabled or unavailable");
      return 0;
    }
    client = [manager registerClientWithIdentifier:clientIdentifier
        descriptionFilePath:descriptionPath];
    if (client == nil) {
      RCErrorSet(error, 1, "Could not register the Sync Services client");
      return 0;
    }
    [client setEnabled:YES forEntityNames:entities];
    session = RCBeginSession(client,entities);
    if (session == nil) {
      RCErrorSet(error, 1, "Could not begin a Sync Services session");
      return 0;
    }
    /* Address Book's entities form one object graph. Sync Services requires
       related entities to use the same slow/fast mode, even when this client
       has no records for some of those entities. */
    [session clientWantsToPushAllRecordsForEntityNames:entities];
    {
      NSEnumerator *keys = [records keyEnumerator];
      NSString *key;
      while ((key = [keys nextObject]) != nil) {
        NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
        @try {
          NSDictionary *record = [records objectForKey:key];
          if (![session shouldPushChangesForEntityName:
                  [record objectForKey:ISyncRecordEntityNameKey]]) {
            RCErrorSet(error, 1, "Sync Services did not permit the contact push");
            goto finished;
          }
          RCSessionPush(session,record,key);
        } @catch(id exception) {
          RCDrainPoolPreservingException(&resourcePool,exception); @throw;
        } @finally { [resourcePool release]; }
      }
    }
    {
      NSEnumerator *enumerator = [entities objectEnumerator];
      NSString *entity;
      while ((entity = [enumerator nextObject]) != nil) {
        if ([session shouldPullChangesForEntityName:entity]) {
          [pullEntities addObject:entity];
        }
      }
    }
    /* Push-only sessions must also enter the merge phase and check its result. */
    if (!RCPrepareToPull(session,pullEntities)) {
      RCErrorSet(error, 1, "Sync Services could not merge contact changes");
      goto finished;
    }
    if ([pullEntities count] != 0) {
      {
        NSEnumerator *changes =
            [session changeEnumeratorForEntityNames:pullEntities];
        ISyncChange *change;
        while ((change = [changes nextObject]) != nil) {
          NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
          @try {
            if ([change type] != ISyncChangeTypeDelete) {
              [session clientRefusedChangesForRecordWithIdentifier:
                  [change recordIdentifier]];
            }
          } @catch(id exception) {
            RCDrainPoolPreservingException(&resourcePool,exception); @throw;
          } @finally { [resourcePool release]; }
        }
      }
      [session clientCommittedAcceptedChanges];
    }
    [session finishSyncing];
    session = nil;
    if (!RCContactStoreMarkPublished(store, generation, error)) goto finished;
    if (recordCount != NULL) *recordCount = mappedCount;
    success = 1;
  }
  @catch (NSException *exception) {
    RCErrorSet(error, 1, "Sync Services exception: %s",
        [[exception name] UTF8String] != NULL ?
        [[exception name] UTF8String] : "unknown error");
  }

finished:
  if (session != nil) {
    @try { [session cancelSyncing]; }
    @catch (NSException *cancelException) {
      RCLogger(RCLogWarning, "Contacts", "Apply", @"Could not cancel Sync Services session: %@", [cancelException name]);
    }
  }
  return success;
}

int RCSyncServicesPushContacts(RCContactStore *store,
                               const char *clientDescriptionPath,
                               long *recordCount, RCError *error)
{
  return RCSyncServicesPushContactsForClient(store, clientDescriptionPath,
      store == NULL ? nil : RCContactSyncClientIdentifier(
          RCString(RCContactStoreSyncIdentifier(store))), recordCount, error);
}

int RCSyncServicesPushTestContacts(RCContactStore *store,
                                   const char *clientDescriptionPath,
                                   long *recordCount, RCError *error)
{
  return RCSyncServicesPushContactsForClient(store, clientDescriptionPath,
      kRCTestClientIdentifier, recordCount, error);
}

int RCSyncServicesUnregisterTestClient(RCError *error)
{
  ISyncManager *manager;
  ISyncClient *client;

  RCErrorClear(error);
  @try {
    manager = [ISyncManager sharedManager];
    if (![manager isEnabled]) {
      RCErrorSet(error, 1, "Sync Services is disabled or unavailable");
      return 0;
    }
    client = [manager clientWithIdentifier:kRCTestClientIdentifier];
    if (client != nil) [manager unregisterClient:client];
  }
  @catch (NSException *exception) {
    const char *reason = [[exception name] UTF8String];
    RCErrorSet(error, 1, "Sync Services exception: %s",
               reason != NULL ? reason : "unknown error");
    return 0;
  }
  return 1;
}
