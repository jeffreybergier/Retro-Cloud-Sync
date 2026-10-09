#ifndef RC_SYNC_BACKEND_H
#define RC_SYNC_BACKEND_H
#import <Foundation/Foundation.h>
#include "RCContactStore.h"
#include "RCCalendarStore.h"
/* Publication boundary used by the worker. DAV and journal ownership remain
   shared. descriptionPath is used only by the legacy SyncServices backend.
   Count -1 means partial publication; it must not advance full success. */
typedef struct {
  const char *name;
  void (*requestAccess)(BOOL contacts,BOOL calendars);
  BOOL (*waitForAccess)(BOOL contacts,RCError *);
  int (*syncContacts)(RCContactStore *,const char *descriptionPath,BOOL twoWay,long *,RCError *);
  int (*syncCalendars)(RCCalendarStore *,const char *descriptionPath,BOOL twoWay,long *,RCError *);
} RCSyncBackend;
/* Supplied by the target's composition unit. No framework probing/fallback
   after a failed operation: backend selection is a platform policy. */
const RCSyncBackend *RCCurrentSyncBackend(void);
#endif
