#ifndef RC_MAC_NATIVE_BACKEND_H
#define RC_MAC_NATIVE_BACKEND_H
#import "RCSyncBackend.h"
#import "RCNativeStore.h"
BOOL RCUsesNativeStoresForVersion(int major,int minor);
BOOL RCUsesNativeStores(void);
void RCMacNativeRequestAccess(BOOL contacts,BOOL calendars);
BOOL RCMacNativeWaitForAccess(BOOL contacts,RCError *error);
/* Returns a retained store. */
id<RCNativeStore> RCCreateMacNativeStore(RCTwoWayContext *,RCError *);
int RCNativeSyncContacts(RCContactStore *,BOOL,long *,RCError *);
int RCNativeSyncCalendars(RCCalendarStore *,BOOL,long *,RCError *);
#endif
