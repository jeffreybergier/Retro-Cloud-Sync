#ifndef RC_CALENDAR_SYNC_SERVICES_BRIDGE_H
#define RC_CALENDAR_SYNC_SERVICES_BRIDGE_H
#include "RCCalendarStore.h"
int RCSyncServicesPushCalendars(RCCalendarStore *, const char *, int testClient, long *,
                                RCError *);
int RCSyncServicesUnregisterCalendarTestClient(RCError *);
#endif
