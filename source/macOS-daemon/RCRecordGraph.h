#ifndef RC_RECORD_GRAPH_H
#define RC_RECORD_GRAPH_H
#import <Foundation/Foundation.h>
/* Preserve the historical serialized key and entity names. SyncServices is
   one consumer of this graph, not a dependency of its representation. */
#define RCRecordEntityNameKey @"com.apple.syncservices.RecordEntityName"
#endif
