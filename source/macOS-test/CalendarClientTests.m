#import "../macOS-daemon/RCCalendarSyncClient.h"
#import <SyncServices/SyncServices.h>
#include <stdio.h>

/* Exercise the production identifier with synthetic account IDs, without
   starting a sync session, accessing credentials, or publishing any records. */
int main(int argc, char **argv)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSString *account = @"00000000000000000000000000000001";
  NSString *identifier = RCCalendarSyncClientIdentifier(account);
  ISyncManager *manager = [ISyncManager sharedManager];
  ISyncClient *client = nil;
  int ok = 0;

  if (argc != 2) {
    fprintf(stderr, "Usage: %s CalendarTestSyncClient.plist\n", argv[0]);
    [pool release];
    return 2;
  }
  @try {
    if (![identifier hasSuffix:account] ||
        ![identifier isEqual:RCCalendarSyncClientIdentifier(account)] ||
        [identifier isEqual:RCCalendarSyncClientIdentifier(
                                @"00000000000000000000000000000002")]) {
      fprintf(stderr, "Calendar client identity is not stable and account-specific\n");
    } else if ([manager clientWithIdentifier:identifier]) {
      fprintf(stderr, "Refusing to replace an existing regression-test client\n");
    } else {
      printf("Production client identifier: %lu characters, %lu encoded filename bytes\n",
             (unsigned long)[identifier length], (unsigned long)[identifier length] * 4);
      client = [manager registerClientWithIdentifier:identifier
                                descriptionFilePath:[NSString stringWithUTF8String:argv[1]]];
      ok = client != nil && [manager clientWithIdentifier:identifier] != nil &&
           [identifier length] * 4 <= 255;
    }
  } @catch (NSException *exception) {
    fprintf(stderr, "Calendar client registration failed: %s\n",
            [[exception reason] UTF8String]);
  }
  if (client) {
    @try {
      [manager unregisterClient:client];
      if ([manager clientWithIdentifier:identifier]) ok = 0;
    } @catch (NSException *exception) {
      fprintf(stderr, "Calendar client cleanup failed: %s\n",
              [[exception reason] UTF8String]);
      ok = 0;
    }
  }
  if (ok) printf("[PASS] Production calendar client registers and cleans up on this Mac\n");
  [pool release];
  return ok ? 0 : 1;
}
