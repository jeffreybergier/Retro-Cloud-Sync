#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>
#include <stdio.h>
#import "../../../macOS-daemon/RCSyncConflictSession.h"
#import "../../../macOS-daemon/RCContactConflictResolver.h"
#include <string.h>

static RCError testError;
#define REQUIRE(x) do { if (!(x)) [NSException raise:@"TestFailure" \
    format:@"%s: %s", #x, testError.message]; } while (0)

static NSString *entity = @"com.apple.contacts.Contact";
static NSString *marker = @"RetroCloudConflictFixture-20260906";
static const char *baseBody="BEGIN:VCARD\r\nVERSION:3.0\r\nUID:conflict-fixture\r\nN:Fixture;Conflict;;;\r\nFN:Conflict Fixture\r\nNOTE:base\r\nTITLE:base\r\nEND:VCARD\r\n";
static const char *localBody="BEGIN:VCARD\r\nVERSION:3.0\r\nUID:conflict-fixture\r\nN:Fixture;Conflict;;;\r\nFN:Conflict Fixture\r\nNOTE:local\r\nTITLE:base\r\nEND:VCARD\r\n";
static const char *remoteBody="BEGIN:VCARD\r\nVERSION:3.0\r\nUID:conflict-fixture\r\nN:Fixture;Conflict;;;\r\nFN:Conflict Fixture\r\nNOTE:base\r\nTITLE:remote\r\nX-APPLE-PRIVATE;X-PARAM=keep:preserve\r\nPHOTO;ENCODING=b:YWJj\r\nEND:VCARD\r\n";

typedef struct { RCWriteJournal journal; ISyncClient *client; } Completion;
static int SaveMirror(void *opaque, const RCWriteOperation *o, RCError *error)
{
  Completion *c=opaque;
  sqlite3_stmt *q=NULL;
  int ok;
  if (sqlite3_prepare_v2(c->journal.db,"INSERT OR REPLACE INTO fixture_mirror VALUES(1,?,?)",
      -1,&q,NULL)!=SQLITE_OK) return 0;
  sqlite3_bind_text(q,1,o->resultETag,-1,SQLITE_TRANSIENT);
  sqlite3_bind_blob(q,2,o->resultBody,(int)o->resultLength,SQLITE_TRANSIENT);
  ok=sqlite3_step(q)==SQLITE_DONE;
  sqlite3_finalize(q);
  if (!ok) RCErrorSet(error,1,"Synthetic mirror failed");
  return ok;
}
static int AcceptLocal(void *opaque, const RCWriteOperation *o,
    const void *receipt, size_t length, RCError *error)
{
  Completion *c=opaque;
  return RCContactAcceptConflict(c->client,o,receipt,length,error);
}
static NSMutableDictionary *card(NSString *note, NSString *title)
{
  return [NSMutableDictionary dictionaryWithObjectsAndKeys:entity,
      ISyncRecordEntityNameKey, marker, @"first name", @"Fixture", @"last name",
      note, @"notes", title, @"job title", nil];
}
static NSDictionary *syncClient(ISyncClient *client, NSDictionary *push,
                                 BOOL accept, BOOL remove)
{
  NSArray *entities = [NSArray arrayWithObject:entity];
  ISyncSession *s = [ISyncSession beginSessionWithClient:client entityNames:entities
      beforeDate:[NSDate dateWithTimeIntervalSinceNow:30]];
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  ISyncChange *change;
  NSEnumerator *it;
  if (!s) [NSException raise:@"TestFailure" format:@"No session"];
  if (push) [s pushChangesFromRecord:push withIdentifier:@"fixture"];
  if (remove) [s deleteRecordWithIdentifier:@"fixture"];
  if (![s prepareToPullChangesForEntityNames:entities
      beforeDate:[NSDate dateWithTimeIntervalSinceNow:30]]) {
    [s cancelSyncing];
    [NSException raise:@"TestFailure" format:@"No merge"];
  }
  it = [s changeEnumeratorForEntityNames:entities];
  while ((change = [it nextObject])) {
    NSDictionary *record = [change record];
    if ([[record objectForKey:@"first name"] isEqual:marker]) {
      [result addEntriesFromDictionary:record];
      if (accept) [s clientAcceptedChangesForRecordWithIdentifier:[change recordIdentifier]
          formattedRecord:nil newRecordIdentifier:@"fixture"];
    } else if ([change type]==ISyncChangeTypeDelete &&
        [[change recordIdentifier] isEqual:@"fixture"] && accept) {
      [s clientAcceptedChangesForRecordWithIdentifier:@"fixture"
          formattedRecord:nil newRecordIdentifier:nil];
    }
  }
  if (accept) { [s clientCommittedAcceptedChanges]; [s finishSyncing]; }
  else [s cancelSyncing];
  return result;
}
static void CheckOwnedFixture(ISyncManager *manager, ISyncClient *client)
{
  if (!client) return;
  NSDictionary *record=[[[manager snapshotOfRecordsInTruthWithEntityNames:
      [NSArray arrayWithObject:entity] usingIdentifiersForClient:client]
      recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"];
  if (record && ![[record objectForKey:@"first name"] isEqual:marker])
    [NSException raise:@"TestFailure" format:@"Fixture belongs to another run; cleanup refused"];
}
int RCSessionCancellationTests(void);
int main(int argc, char **argv)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  if (!RCSessionCancellationTests()) { fprintf(stderr,"Session cancellation checks failed\n"); return 1; }
  if(argc==2 && !strcmp(argv[1],"--cancellation-only")) { puts("Session cancellation checks passed"); [pool release]; return 0; }
  ISyncManager *manager = [ISyncManager sharedManager];
  ISyncClient *remote = nil, *local = nil;
  int status = 1;
  Completion completion;
  memset(&completion,0,sizeof(completion));
  if (argc>2 || (argc==2 && strcmp(argv[1],"--cleanup"))) {
    fprintf(stderr,"Usage: ConflictSessionTests [--cleanup]\n");
    [pool release]; return 1;
  }
  @try {
    if (argc==2) {
      NSString *saved=[NSString stringWithContentsOfFile:@"fixture-marker.txt"
          encoding:NSUTF8StringEncoding error:NULL];
      REQUIRE([saved hasPrefix:@"RetroCloudConflictFixture-"]);
      marker=saved;
      remote=[manager clientWithIdentifier:@"com.retrocloudsync.conflict.test.remote"];
      local=[manager clientWithIdentifier:@"com.retrocloudsync.conflict.test.local"];
    } else {
    NSDictionary *description = [NSDictionary dictionaryWithObjectsAndKeys:
        @"server", @"Type", @"Retro Cloud Conflict Tests", @"DisplayName",
        [NSDictionary dictionaryWithObject:[NSArray arrayWithObjects:
            ISyncRecordEntityNameKey, @"first name", @"last name", @"notes",
            @"job title", nil] forKey:entity], @"Entities", nil];
    [description writeToFile:@"ConflictClient.plist" atomically:YES];
    NSString *path = [[[NSFileManager defaultManager] currentDirectoryPath]
        stringByAppendingPathComponent:@"ConflictClient.plist"];
    if ([manager clientWithIdentifier:@"com.retrocloudsync.conflict.test.remote"] ||
        [manager clientWithIdentifier:@"com.retrocloudsync.conflict.test.local"])
      [NSException raise:@"TestFailure" format:@"Previous test clients require recovery"];
    marker=[@"RetroCloudConflictFixture-" stringByAppendingString:
        [[NSProcessInfo processInfo] globallyUniqueString]];
    REQUIRE([marker writeToFile:@"fixture-marker.txt" atomically:YES
        encoding:NSUTF8StringEncoding error:NULL]);
    remote = [manager registerClientWithIdentifier:@"com.retrocloudsync.conflict.test.remote"
        descriptionFilePath:path];
    local = [manager registerClientWithIdentifier:@"com.retrocloudsync.conflict.test.local"
        descriptionFilePath:path];
    if (!remote || !local) [NSException raise:@"TestFailure" format:@"Registration"];
    [remote setEnabled:YES forEntityNames:[NSArray arrayWithObject:entity]];
    [local setEnabled:YES forEntityNames:[NSArray arrayWithObject:entity]];
    syncClient(remote, card(@"base", @"base"), YES, NO);
    syncClient(local, nil, YES, NO);
    syncClient(local, card(@"local", @"base"), YES, NO);
    NSDictionary *pending = syncClient(remote, nil, NO, NO);
    fprintf(stderr, "Pending local note: %s\n", [[pending objectForKey:@"notes"] UTF8String]);
    REQUIRE([[pending objectForKey:@"notes"] isEqual:@"local"]);
    completion.client=remote; completion.journal.account=1;
    REQUIRE(sqlite3_open("ConflictRecovery.sqlite",&completion.journal.db)==SQLITE_OK);
    REQUIRE(sqlite3_exec(completion.journal.db,"PRAGMA foreign_keys=ON;"
        "CREATE TABLE accounts(id INTEGER PRIMARY KEY);INSERT INTO accounts VALUES(1);"
        "CREATE TABLE fixture_mirror(id INTEGER PRIMARY KEY,etag TEXT,body BLOB)",NULL,NULL,NULL)==SQLITE_OK);
    REQUIRE(RCWriteJournalInitialize(completion.journal.db,&testError));
    REQUIRE(RCWriteJournalSetBase(&completion.journal,"fixture","https://fixture.invalid/contact.vcf",
        "\"base\"",baseBody,strlen(baseBody),1,&testError));
    long long operation,successor;
    REQUIRE(RCWriteJournalEnqueue(&completion.journal,"local-edit","fixture",
        "https://fixture.invalid/contact.vcf","update",1,localBody,strlen(localBody),&operation,&testError));
    REQUIRE(RCWriteJournalBeginAttempt(&completion.journal,operation,100,&testError));
    REQUIRE(RCWriteJournalRecordResult(&completion.journal,operation,"conflict",200,
        "\"remote\"",remoteBody,strlen(remoteBody),&testError));
    REQUIRE(RCContactRecoverConflict(&completion.journal,operation,remote,
        [NSDictionary dictionaryWithObject:card(@"base",@"base") forKey:@"fixture"],
        @"fixture",&successor,&testError) && successor);
    RCWriteOperation resolved;
    REQUIRE(RCWriteJournalGet(&completion.journal,successor,&resolved,&testError));
    REQUIRE(strstr((const char *)resolved.desiredBody,"NOTE:local\r\n"));
    REQUIRE(strstr((const char *)resolved.desiredBody,"TITLE:remote\r\n"));
    REQUIRE(strstr((const char *)resolved.desiredBody,"X-APPLE-PRIVATE;X-PARAM=keep:preserve\r\n"));
    REQUIRE(strstr((const char *)resolved.desiredBody,"PHOTO;ENCODING=b:YWJj\r\n"));
    puts("PASS: Real Tiger reconciliation retains local intent, remote edits and unrepresented vCard fields");
    REQUIRE(RCWriteJournalBeginAttempt(&completion.journal,successor,200,&testError));
    REQUIRE(RCWriteJournalRecordResult(&completion.journal,successor,"applied",200,
        "\"confirmed\"",resolved.desiredBody,resolved.desiredLength,&testError));
    RCWriteOperationClear(&resolved);
    RCConflictCallbacks callbacks;
    memset(&callbacks,0,sizeof(callbacks)); callbacks.context=&completion;
    callbacks.saveMirror=SaveMirror; callbacks.acceptLocal=AcceptLocal;
    REQUIRE(RCConflictComplete(&completion.journal,successor,&callbacks,&testError));
    REQUIRE(RCConflictComplete(&completion.journal,successor,&callbacks,&testError));
    puts("PASS: Mirror completion and exact Sync Services acknowledgement are replayable");
    void *receiptBytes=NULL; size_t receiptLength; int mirrored;
    REQUIRE(RCWriteJournalResolutionReceipt(&completion.journal,successor,&receiptBytes,
        &receiptLength,&mirrored,&testError));
    NSDictionary *receipt=[NSPropertyListSerialization propertyListFromData:
        [NSData dataWithBytes:receiptBytes length:receiptLength]
        mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:NULL];
    free(receiptBytes);
    syncClient(local,nil,YES,NO);
    syncClient(local,card(@"newer",@"remote"),YES,NO);
    REQUIRE(!RCSyncAcceptConflictResolution(remote,receipt,&testError));
    pending=syncClient(remote,nil,NO,NO);
    REQUIRE([[pending objectForKey:@"notes"] isEqual:@"newer"]);
    puts("PASS: A newer local edit is never acknowledged by an older receipt");
    NSDictionary *sameField=RCSyncResolveConflict(remote,
        [NSDictionary dictionaryWithObject:card(@"remote-choice",@"remote") forKey:@"fixture"],
        [NSArray arrayWithObject:@"fixture"],&testError);
    NSString *choice=[[sameField objectForKey:@"fixture"] objectForKey:@"notes"];
    REQUIRE([choice isEqual:@"newer"] || [choice isEqual:@"remote-choice"]);
    puts("PASS: Same-field decisions come from the system's post-merge snapshot");
    REQUIRE(RCSyncAcceptConflictResolution(remote,sameField,&testError));
    syncClient(local,nil,YES,NO);
    REQUIRE(RCWriteJournalEnqueue(&completion.journal,"deleted-remotely","fixture",
        "https://fixture.invalid/contact.vcf","update",1,localBody,strlen(localBody),&operation,&testError));
    REQUIRE(RCWriteJournalBeginAttempt(&completion.journal,operation,300,&testError));
    REQUIRE(RCWriteJournalRecordResult(&completion.journal,operation,"conflict",404,
        NULL,NULL,0,&testError));
    REQUIRE(RCContactRecoverConflict(&completion.journal,operation,remote,
        sameField,@"fixture",&successor,&testError) && !successor);
    REQUIRE(RCWriteJournalNextConflict(&completion.journal,&successor,&testError) && !successor);
    puts("PASS: Edit-versus-delete remains a durable attention case without resurrection");
    NSDictionary *wrongIntent=[NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:@"not-the-pending-local-edit" forKey:@"notes"]
        forKey:@"fixture"];
    REQUIRE(!RCSyncResolveConflictWithIntent(remote,sameField,
        [NSArray arrayWithObject:@"fixture"],wrongIntent,&testError));
    puts("PASS: Missing or superseded local intent prevents a remote publication");
    }
    status = 0;
  } @catch (NSException *e) { fprintf(stderr, "%s\n", [[e reason] UTF8String]); }
  @try {
    CheckOwnedFixture(manager,local);
    CheckOwnedFixture(manager,remote);
    if (local) syncClient(local, nil, YES, YES);
    if (remote) syncClient(remote, nil, YES, YES);
    NSDictionary *remaining=[[manager snapshotOfRecordsInTruthWithEntityNames:
        [NSArray arrayWithObject:entity] usingIdentifiersForClient:nil]
        recordsWithMatchingAttributes:[NSDictionary dictionaryWithObject:marker forKey:@"first name"]];
    REQUIRE(![remaining count]);
    if (remote) [manager unregisterClient:remote];
    if (local) [manager unregisterClient:local];
  } @catch (NSException *e) { fprintf(stderr, "Cleanup: %s\n", [[e reason] UTF8String]); status = 1; }
  if (completion.journal.db) sqlite3_close(completion.journal.db);
  [pool release];
  return status;
}
