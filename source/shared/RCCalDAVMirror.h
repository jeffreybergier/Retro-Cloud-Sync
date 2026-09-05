#ifndef RC_CALDAV_MIRROR_H
#define RC_CALDAV_MIRROR_H
#include "RCCalendarStore.h"
#include "RCCardDAVMirror.h"
/* Same transport credentials/progress contract as the contact mirror. */
int RCCalDAVMirrorFetch(const RCCardDAVMirrorConfig *, RCCalendarStore *,
                        RCCardDAVMirrorResult *, RCError *);
#endif
