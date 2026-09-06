#ifndef RC_CALDAV_MIRROR_H
#define RC_CALDAV_MIRROR_H
#include "RCCalendarStore.h"
#include "RCCardDAVMirror.h"
/* Same transport credentials/progress contract as the contact mirror. */
int RCCalDAVMirrorFetch(const RCCardDAVMirrorConfig *, RCCalendarStore *,
                        RCCardDAVMirrorResult *, RCError *);
/* NULL start retains the complete-inventory behavior. Otherwise inventory only
   VEVENT resources overlapping [start, infinity), retaining their entire bodies. */
int RCCalDAVMirrorFetchSince(const RCCardDAVMirrorConfig *, RCCalendarStore *,
                             const char *start, RCCardDAVMirrorResult *, RCError *);
/* UTC calendar date (YYYYMMDD), 1 or 2 years; clamps February 29 to February 28. */
int RCCalDAVHistoryStart(const char *today, int years, char start[17], RCError *);
#endif
