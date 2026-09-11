#import "RCStatus.h"
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"Status test failed at line %d\n",__LINE__); return 0; } } while(0)
static NSDictionary *Read(NSString *path) { return [[NSDictionary dictionaryWithContentsOfFile:path] objectForKey:@"Contacts"]; }
int RCStatusTests(void)
{
  char directory[]="StatusTests-XXXXXX";
  CHECK(mkdtemp(directory));
  NSString *root=[NSString stringWithUTF8String:directory];
  NSString *config=[root stringByAppendingPathComponent:@"Configuration.plist"];
  NSString *path=[root stringByAppendingPathComponent:@"Status.plist"];
  NSMutableDictionary *settings=[NSMutableDictionary dictionaryWithObjectsAndKeys:@"first",@"Username",@"TwoWay",@"ContactsSyncMode",@"Disabled",@"CalendarsSyncMode",nil];
  NSDictionary *configuration=[NSDictionary dictionaryWithObject:settings forKey:@"Contacts"];
  RCWriteJournal j; memset(&j,0,sizeof(j)); j.account=1;
  CHECK(sqlite3_open(":memory:",&j.db)==SQLITE_OK);
  RCStatusStart(config,configuration);
  CHECK([[Read(path) objectForKey:@"Phase"] isEqual:@"Waiting"]);
  RCStatusFinish(@"Contacts",&j,YES);
  CHECK([[Read(path) objectForKey:@"Phase"] isEqual:@"UpToDate"]);
  NSDate *last=[Read(path) objectForKey:@"LastSuccess"];
  CHECK(last);
  RCStatusPhase(@"Contacts",@"Waiting"); RCStatusFailure(@"Contacts",@"Download");
  RCStatusPhase(@"Contacts",@"Applying"); RCStatusFinish(@"Contacts",&j,YES);
  CHECK([[Read(path) objectForKey:@"Phase"] isEqual:@"Error"]);
  CHECK([[Read(path) objectForKey:@"LastSuccess"] isEqual:last]);
  RCStatusSchedule(60);
  CHECK([[Read(path) objectForKey:@"NextAttempt"] isKindOfClass:[NSDate class]]);
  CHECK(sqlite3_exec(j.db,"CREATE TABLE two_way_attention(account_id INTEGER); INSERT INTO two_way_attention VALUES(1); INSERT INTO two_way_attention VALUES(2)",NULL,NULL,NULL)==SQLITE_OK);
  RCStatusPhase(@"Contacts",@"Waiting"); RCStatusFinish(@"Contacts",&j,YES);
  CHECK([[Read(path) objectForKey:@"Phase"] isEqual:@"Attention"]);
  CHECK([[Read(path) objectForKey:@"PendingCount"] intValue]==1);
  RCStatusStop(); CHECK(![[[NSDictionary dictionaryWithContentsOfFile:path] objectForKey:@"Running"] boolValue]);
  RCStatusStart(config,configuration); CHECK([[Read(path) objectForKey:@"LastSuccess"] isEqual:last]);
  [settings setObject:@"second" forKey:@"Username"]; RCStatusStart(config,configuration);
  CHECK(![Read(path) objectForKey:@"LastSuccess"]);
  struct stat st; CHECK(stat([path fileSystemRepresentation],&st)==0 && (st.st_mode&0777)==0600);
  /* A broken optional table must not report success. */
  CHECK(sqlite3_exec(j.db,"DROP TABLE two_way_attention; CREATE TABLE two_way_attention(broken INTEGER)",NULL,NULL,NULL)==SQLITE_OK);
  RCStatusFinish(@"Contacts",&j,YES); CHECK([[Read(path) objectForKey:@"Phase"] isEqual:@"Attention"]);
  RCStopRequested=1;
  RCStatusFailure(@"Contacts",@"Download"); RCStatusSchedule(60);
  CHECK([[Read(path) objectForKey:@"Phase"] isEqual:@"Stopping"]);
  CHECK(![Read(path) objectForKey:@"ErrorCode"] && ![Read(path) objectForKey:@"NextAttempt"]);
  RCStatusStop(); RCStopRequested=0;
  sqlite3_close(j.db); unlink([path fileSystemRepresentation]); rmdir(directory);
  return 1;
}
