#import "RCMacNativeBackend.h"
#import "RCTwoWayNative.h"
static BOOL Exchange(RCTwoWayContext *context,BOOL twoWay,RCError *error)
{
  return RCNativeExchange(context,twoWay,RCCreateMacNativeStore,error);
}

int RCNativeSyncContacts(RCContactStore *store,BOOL twoWay,long *count,RCError *error)
{ return RCExchangeContacts(store,NULL,Exchange,twoWay,count,error); }
int RCNativeSyncCalendars(RCCalendarStore *store,BOOL twoWay,long *count,RCError *error)
{ return RCExchangeCalendars(store,NULL,Exchange,YES,twoWay,count,error); }
static int Contacts(RCContactStore *store,const char *description,BOOL twoWay,long *count,RCError *error)
{ (void)description; return RCNativeSyncContacts(store,twoWay,count,error); }
static int Calendars(RCCalendarStore *store,const char *description,BOOL twoWay,long *count,RCError *error)
{ (void)description; return RCNativeSyncCalendars(store,twoWay,count,error); }
const RCSyncBackend RCMacNativeBackend = {
  "mac-addressbook-eventkit", RCMacNativeRequestAccess, RCMacNativeWaitForAccess, Contacts, Calendars
};
