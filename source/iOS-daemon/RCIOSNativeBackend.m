#import "RCIOSNativeBackend.h"
#import "RCIOSAccess.h"
#import "RCTwoWayNative.h"
static BOOL Exchange(RCTwoWayContext *c,BOOL twoWay,RCError *e) { return RCNativeExchange(c,twoWay,RCCreateIOSNativeStore,e); }
static int Contacts(RCContactStore *s,const char *path,BOOL twoWay,long *n,RCError *e) {
  (void)path; return RCExchangeContacts(s,NULL,Exchange,twoWay,n,e);
}
static int Calendars(RCCalendarStore *s,const char *path,BOOL twoWay,long *n,RCError *e) {
  (void)path; return RCExchangeCalendars(s,NULL,Exchange,YES,twoWay,n,e);
}
const RCSyncBackend *RCCurrentSyncBackend(void) {
  static const RCSyncBackend backend={"ios-addressbook-eventkit",RCIOSRequestAccess,RCIOSWaitForAccess,Contacts,Calendars};
  return &backend;
}
