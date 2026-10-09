#ifndef RC_CALENDAR_GRAPH_H
#define RC_CALENDAR_GRAPH_H
#import <Foundation/Foundation.h>
#include "RCCalendarStore.h"
NSMutableDictionary *RCCalendarResourceGraph(RCCalendarStore *,long long,NSString *,
    const unsigned char *,size_t,RCError *);
#endif
