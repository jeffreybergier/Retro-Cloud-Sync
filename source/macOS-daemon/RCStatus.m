#import "RCStatus.h"
#include "RCStatusPolicy.h"
#import "RCLogger.h"
#include <openssl/sha.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

static NSMutableDictionary *status;
static NSString *path;
static void Save(void)
{
  if (!path) return;
  [status setObject:[NSDate date] forKey:@"UpdatedAt"];
  /* Atomic replacement; the temporary inode is private before any data is written. */
  NSData *data=[NSPropertyListSerialization dataFromPropertyList:status
      format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL];
  NSString *temporary=[path stringByAppendingString:@".XXXXXX"];
  char *name=strdup([temporary fileSystemRepresentation]);
  if(!name) return;
  int fd=mkstemp(name); BOOL ok=fd>=0;
  const unsigned char *bytes=[data bytes]; NSUInteger remaining=[data length];
  if (!data) ok=NO;
  while(ok && remaining) {
    ssize_t n=write(fd,bytes,remaining);
    if(n<0 && errno==EINTR) continue;
    if(n<=0) { ok=NO; break; }
    bytes+=n; remaining-=n;
  }
  if(fd>=0) { if(fsync(fd)!=0) ok=NO; if(close(fd)!=0) ok=NO; }
  if(ok) ok=rename(name,[path fileSystemRepresentation])==0;
  if(!ok) { unlink(name); RCLogger(RCLogWarning,"Daemon","Status",@"Could not save status snapshot"); }
  free(name);
}
static NSMutableDictionary *Service(NSString *name) { return [status objectForKey:name]; }
void RCStatusStart(NSString *configurationPath, NSDictionary *configuration)
{
  if (!configurationPath) return;
  [path release]; path=[[[configurationPath stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"Status.plist"] copy];
  NSDictionary *old=[NSDictionary dictionaryWithContentsOfFile:path];
  id settings=[configuration objectForKey:@"Contacts"];
  if(![settings isKindOfClass:[NSDictionary class]]) settings=[NSDictionary dictionary];
  id username=[settings objectForKey:@"Username"];
  if(![username isKindOfClass:[NSString class]]) username=@"";
  NSData *account=[[username lowercaseString] dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[SHA256_DIGEST_LENGTH]; SHA256([account bytes],[account length],digest);
  NSData *identity=[NSData dataWithBytes:digest length:sizeof(digest)];
  [status release]; status=[[NSMutableDictionary alloc] init];
  [status setObject:identity forKey:@"AccountIdentity"];
  [status setObject:[NSNumber numberWithInt:1] forKey:@"Version"];
  [status setObject:[NSNumber numberWithInt:getpid()] forKey:@"PID"];
  [status setObject:[NSNumber numberWithBool:YES] forKey:@"Running"];
  NSArray *names=[NSArray arrayWithObjects:@"Contacts",@"Calendars",nil];
  NSEnumerator *e=[names objectEnumerator]; NSString *name;
  while((name=[e nextObject])) {
    NSString *mode=[settings objectForKey:[name stringByAppendingString:@"SyncMode"]];
    BOOL enabled=[mode isEqual:@"OneWay"] || [mode isEqual:@"TwoWay"];
    if(!mode) enabled=[[settings objectForKey:[name isEqual:@"Contacts"] ? @"Enabled" : @"CalendarsEnabled"] boolValue];
    NSMutableDictionary *s=[NSMutableDictionary dictionaryWithObjectsAndKeys:
        enabled ? @"Waiting" : @"Disabled",@"Phase",@"yellow",@"Severity",nil];
    id prior=[old objectForKey:name];
    if([[old objectForKey:@"AccountIdentity"] isEqual:identity] && [prior isKindOfClass:[NSDictionary class]]) {
      id last=[prior objectForKey:@"LastSuccess"];
      if([last isKindOfClass:[NSDate class]]) [s setObject:last forKey:@"LastSuccess"];
    }
    [status setObject:s forKey:name];
  }
  Save();
}
void RCStatusPhase(NSString *name, NSString *phase)
{
  @synchronized(status) {
  if(RCStopRequested) { RCStatusStopping(); return; }
  NSMutableDictionary *s=Service(name);
  if([phase isEqual:@"Waiting"]) { [s removeObjectForKey:@"ErrorCode"]; [s removeObjectForKey:@"PendingCount"]; }
  [s removeObjectForKey:@"NextAttempt"];
  [s setObject:phase forKey:@"Phase"]; [s setObject:[s objectForKey:@"ErrorCode"] ? @"red" : @"yellow" forKey:@"Severity"]; Save();

  }
}
void RCStatusFailure(NSString *name, NSString *code)
{
  @synchronized(status) {
  if(RCStopRequested) { RCStatusStopping(); return; }
  NSMutableDictionary *s=Service(name);
  if(![s objectForKey:@"ErrorCode"]) [s setObject:code forKey:@"ErrorCode"];
  [s setObject:@"Error" forKey:@"Phase"]; [s setObject:@"red" forKey:@"Severity"]; Save();

  }
}
void RCStatusFinish(NSString *name, RCWriteJournal *j, BOOL complete)
{
  @synchronized(status) {
  if(RCStopRequested) { RCStatusStopping(); return; }
  NSMutableDictionary *s=Service(name);
  RCStatusResult result=RCStatusEvaluate(j,[name isEqual:@"Contacts"],complete,
      [s objectForKey:@"ErrorCode"]!=nil,RCStopRequested);
  if(RCStopRequested) { RCStatusStopping(); return; }
  [s setObject:[NSNumber numberWithLong:result.pending] forKey:@"PendingCount"];
  [s setObject:[NSString stringWithUTF8String:result.phase] forKey:@"Phase"];
  [s setObject:[NSString stringWithUTF8String:result.severity] forKey:@"Severity"];
  if(result.advanceSuccess) [s setObject:[NSDate date] forKey:@"LastSuccess"];
  Save();

  }
}
void RCStatusSchedule(unsigned int interval)
{
  @synchronized(status) {
  if(RCStopRequested) { RCStatusStopping(); return; }
  NSEnumerator *e=[[NSArray arrayWithObjects:@"Contacts",@"Calendars",nil] objectEnumerator]; NSString *name;
  while((name=[e nextObject])) if(![[Service(name) objectForKey:@"Phase"] isEqual:@"Disabled"])
    [Service(name) setObject:[NSDate dateWithTimeIntervalSinceNow:interval] forKey:@"NextAttempt"];
  Save();

  }
}
void RCStatusStop(void) {
  @synchronized(status) { [status setObject:[NSNumber numberWithBool:NO] forKey:@"Running"]; Save();
  }
}

void RCStatusStopping(void)
{
  @synchronized(status) {
    [status setObject:[NSNumber numberWithBool:YES] forKey:@"Stopping"];
    NSEnumerator *e=[[NSArray arrayWithObjects:@"Contacts",@"Calendars",nil] objectEnumerator]; NSString *name;
    while((name=[e nextObject])) if(![[Service(name) objectForKey:@"Phase"] isEqual:@"Disabled"]) {
      [Service(name) setObject:@"Stopping" forKey:@"Phase"];
      [Service(name) setObject:@"yellow" forKey:@"Severity"];
      [Service(name) removeObjectForKey:@"ErrorCode"];
      [Service(name) removeObjectForKey:@"NextAttempt"];
    }
    Save();
  }
}
