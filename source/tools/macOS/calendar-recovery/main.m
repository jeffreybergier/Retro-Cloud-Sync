#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>
#import "../../../macOS-daemon/RCNativeCalendarRecovery.h"
#include <sys/stat.h>
#include <unistd.h>
/* Opt-in maintenance tool. Launch as an app for ordinary Calendar permission.
   Usage: app --args DATABASE NEW_BACKUP ROOT [ROOT ...] */
static int Restore(int argc,char **argv)
{
  RCError error; RCErrorClear(&error); sqlite3 *db=NULL; int result=1;
  if(argc<4) { fprintf(stderr,"Usage: CalendarRecovery DATABASE NEW_BACKUP ROOT [ROOT ...]\n"); return 1; }
  NSTask *check=[[[NSTask alloc] init] autorelease];
  [check setLaunchPath:@"/usr/bin/pgrep"]; [check setArguments:[NSArray arrayWithObjects:@"-x",@"rcloudd",nil]];
  [check launch]; [check waitUntilExit];
  if([check terminationStatus]!=1) { fprintf(stderr,"Stop rcloudd before restoration.\n"); return 1; }
  if(sqlite3_open_v2(argv[1],&db,SQLITE_OPEN_READWRITE,NULL)!=SQLITE_OK) goto done;
  sqlite3_busy_timeout(db,5000);
  if(!RCWriteJournalBackup(db,argv[2],&error)) goto done;
  if(!RCMacNativeWaitForAccess(NO,&error)) goto done;
  for(int i=3;i<argc;i++) {
    sqlite3_stmt *q=NULL; long long account=0;
    if(sqlite3_prepare_v2(db,"SELECT account_id FROM native_store_resources WHERE root=?",-1,&q,NULL)!=SQLITE_OK) goto done;
    sqlite3_bind_text(q,1,argv[i],-1,SQLITE_TRANSIENT);
    if(sqlite3_step(q)==SQLITE_ROW) account=sqlite3_column_int64(q,0);
    int step=sqlite3_step(q); sqlite3_finalize(q);
    if(!account || step!=SQLITE_DONE) { RCErrorSet(&error,1,"Root has missing or ambiguous account ownership"); goto done; }
    RCCalendarStore store={db,account,0,0};
    if(!RCNativeRestoreCalendar(&store,[NSString stringWithUTF8String:argv[i]],&error)) goto done;
    printf("Restored %s\n",argv[i]);
  }
  result=0;
done:
  if(result) fprintf(stderr,"Restoration stopped: %s\n",error.code ? error.message : "database error");
  if(db) sqlite3_close(db); return result;
}
int main(int argc,char **argv)
{
  NSAutoreleasePool *pool=[NSAutoreleasePool new]; [NSApplication sharedApplication];
  NSString *log=[@"~/Desktop/rCloud-calendar-recovery.log" stringByExpandingTildeInPath];
  umask(0077); freopen([log fileSystemRepresentation],"w",stdout); dup2(fileno(stdout),fileno(stderr)); setbuf(stdout,NULL);
  __block int status=1;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0),^{
    NSAutoreleasePool *worker=[NSAutoreleasePool new]; status=Restore(argc,argv); [worker release];
    printf("Restoration exit=%d\n",status);
    dispatch_async(dispatch_get_main_queue(),^{ [NSApp stop:nil];
      [NSApp postEvent:[NSEvent otherEventWithType:NSApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO]; });
  });
  [NSApp run]; [pool release]; return status;
}
