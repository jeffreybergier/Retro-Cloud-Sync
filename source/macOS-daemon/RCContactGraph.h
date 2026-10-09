#ifndef RC_CONTACT_GRAPH_H
#define RC_CONTACT_GRAPH_H
#import <Foundation/Foundation.h>
#include "RCContactStore.h"
/* Complete forward mapping. Failure never returns a partial graph. */
NSMutableDictionary *RCContactPublicationGraph(RCContactStore *,long *,RCError *);
#endif
