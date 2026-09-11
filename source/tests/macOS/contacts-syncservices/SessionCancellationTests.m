#import "../../../macOS-daemon/RCSyncConflictSession.h"
#include <stdio.h>
@interface RCBlockedSession : NSObject { @public int calls; id target; SEL selector; }
- (void)prepareToPullChangesInBackgroundForEntityNames:(NSArray *)entities target:(id)value selector:(SEL)action;
- (BOOL)isCancelled;
- (void)cancelSyncing;
@end
@implementation RCBlockedSession
- (void)prepareToPullChangesInBackgroundForEntityNames:(NSArray *)entities target:(id)value selector:(SEL)action
{
  (void)entities; target=value; selector=action;
  calls++; RCStopRequested=1;
}
- (BOOL)isCancelled { return NO; }
- (void)cancelSyncing
{
  [target performSelector:selector withObject:nil withObject:nil];
  [target performSelector:selector withObject:nil withObject:nil];
  target=nil;
}
@end
int RCSessionCancellationTests(void)
{
  RCBlockedSession *session=[[[RCBlockedSession alloc] init] autorelease];
  BOOL cancelled=NO;
  @try { RCPrepareToPull((ISyncSession *)session,[NSArray array]); }
  @catch(NSException *exception) { cancelled=[[exception name] isEqual:@"RCShutdownRequested"]; }
  if(!cancelled || session->calls!=1) return 0;
  cancelled=NO;
  @try { RCBeginSession(nil,[NSArray array]); }
  @catch(NSException *exception) { cancelled=[[exception name] isEqual:@"RCShutdownRequested"]; }
  RCStopRequested=0;
  return cancelled;
}
