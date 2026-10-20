#import "RCTwoWaySync.h"
BOOL RCCalendarCollectOperations(RCWriteJournal *,NSDictionary *,NSDictionary *,NSArray *,NSMutableSet *,RCError *);
BOOL RCCalendarProtectOperations(RCWriteJournal *,NSArray *,NSDictionary *,NSMutableSet *,RCError *);
/* verified counts operations whose remote result and local checkpoint completed
   during this pass, including moves removed from the pending journal. */
BOOL RCCalendarRunOperations(RCWriteJournal *,RCHTTPClient *,long *,RCError *);
/* Worker-thread checkpoint after GET verifies source absence, exact destination
   bytes and a strong destination ETag. Atomically advances mirror and native
   calendar-only receipt; never accepts newer native content edits. */
BOOL RCCalendarCommitVerifiedMove(RCWriteJournal *,NSString *,NSString *,
    NSString *,NSString *,NSData *,RCError *);
