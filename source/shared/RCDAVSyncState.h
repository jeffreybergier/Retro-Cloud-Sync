#ifndef RC_DAV_SYNC_STATE_H
#define RC_DAV_SYNC_STATE_H
#include "RCError.h"
#include "RCSQLite.h"
/* Borrowed account connection. Load is read-only and may precede network work;
   Save and Finish require the mirror's atomic account transaction. */
typedef struct { sqlite3 *db; long long account; } RCDAVSyncState;
int RCDAVSyncStateLoad(RCDAVSyncState *, const char *url, char **token,
                       char **scope, RCError *);
int RCDAVSyncStateSave(RCDAVSyncState *, const char *url, const char *token,
                       const char *scope, long long run, RCError *);
int RCDAVSyncStateFinish(RCDAVSyncState *, long long run, RCError *);
#endif
