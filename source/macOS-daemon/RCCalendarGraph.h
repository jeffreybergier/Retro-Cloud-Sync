#ifndef RC_CALENDAR_GRAPH_H
#define RC_CALENDAR_GRAPH_H
#import <Foundation/Foundation.h>
#include "RCCalendarStore.h"
NSMutableDictionary *RCCalendarResourceGraph(RCCalendarStore *,long long,NSString *,
    const unsigned char *,size_t,RCError *);
/* Read-only validation of every mapped date and derived alarm endpoint.
   No ownership transfer; call before any native mutation on the owning thread. */
BOOL RCCalendarImportGraphDates(NSDictionary *, RCError *);
#endif
