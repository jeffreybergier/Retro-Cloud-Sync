#ifndef RC_SYNC_SERVICES_BACKEND_H
#define RC_SYNC_SERVICES_BACKEND_H
#import "RCTwoWaySync.h"
#include "RCContactStore.h"
#include "RCCalendarStore.h"
BOOL RCSyncServicesExchange(RCTwoWayContext *,RCError *);
int RCSyncServicesTwoWayContacts(RCContactStore *,const char *,long *,RCError *);
int RCSyncServicesTwoWayCalendars(RCCalendarStore *,const char *,long *,RCError *);
#endif
