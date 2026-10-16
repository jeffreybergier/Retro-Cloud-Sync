#ifndef RC_NATIVE_CALENDAR_RECOVERY_H
#define RC_NATIVE_CALENDAR_RECOVERY_H
#import "RCMacNativeBackend.h"
/* Explicitly authorized local overwrite, not automatic conflict resolution.
   Caller must stop the daemon and export a backup first. No network writes.
   Only an existing, owned, non-pending resource may be restored. */
BOOL RCNativeRestoreCalendar(RCCalendarStore *store,NSString *root,RCError *error);
#endif
