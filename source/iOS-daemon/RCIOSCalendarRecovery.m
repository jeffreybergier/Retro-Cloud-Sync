#import "RCIOSAccess.h"
#import "../macOS-daemon/RCNativeCalendarRecovery.h"
#include <signal.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>

/* Explicit local restoration only. Run as mobile after unloading launchd. */
int RCIOSRestoreCalendars(int argc,char **argv)
{
  NSAutoreleasePool *pool=[NSAutoreleasePool new];
  RCError error; RCErrorClear(&error); sqlite3 *db=NULL; int result=1;
  umask(0077);
  NSString *path=[NSString stringWithUTF8String:argv[2]];
  NSDictionary *status=[NSDictionary dictionaryWithContentsOfFile:
      [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Status.plist"]];
  pid_t pid=[[status objectForKey:@"PID"] intValue];
  if(pid>0 && pid!=getpid() && (kill(pid,0)==0 || errno!=ESRCH)) {
    RCErrorSet(&error,1,"Stop the recorded rCloud daemon before restoration"); goto done;
  }
  if(!status) { RCErrorSet(&error,1,"Cannot verify daemon status before restoration"); goto done; }
  if(sqlite3_open_v2(argv[2],&db,SQLITE_OPEN_READWRITE,NULL)!=SQLITE_OK) goto done;
  sqlite3_busy_timeout(db,5000);
  if(!RCWriteJournalBackup(db,argv[3],&error) || !RCIOSWaitForAccess(NO,&error)) goto done;
  for(int i=4;i<argc;i++) {
    sqlite3_stmt *q=NULL; long long account=0;
    if(sqlite3_prepare_v2(db,"SELECT account_id FROM native_store_resources WHERE root=?",-1,&q,NULL)!=SQLITE_OK) goto done;
    sqlite3_bind_text(q,1,argv[i],-1,SQLITE_TRANSIENT);
    if(sqlite3_step(q)==SQLITE_ROW) account=sqlite3_column_int64(q,0);
    int step=sqlite3_step(q); sqlite3_finalize(q);
    if(!account || step!=SQLITE_DONE) { RCErrorSet(&error,1,"Root has missing or ambiguous account ownership"); goto done; }
    RCCalendarStore store={db,account,0,0};
    BOOL removing=!strcmp(argv[1],"--remove-excluded-calendars");
    NSString *root=[NSString stringWithUTF8String:argv[i]];
    if(!(removing ? RCNativeRemoveExcludedCalendar(&store,root,&error) : RCNativeRestoreCalendar(&store,root,&error))) goto done;
    printf("%s %s\n",removing ? "Removed excluded local copy" : "Restored",argv[i]);
  }
  result=0;
done:
  if(result) fprintf(stderr,"Restoration stopped: %s\n",error.code ? error.message : "database error");
  if(db) sqlite3_close(db);
  [pool release]; return result;
}
