#ifndef RC_CALENDAR_STORE_H
#define RC_CALENDAR_STORE_H
#include "RCDAVClient.h"
#include "RCICalendar.h"
#include <AltivecCore/sqlite3.h>
/* One connection belongs to one account worker. SQL is also used by the native
   mapper; never hand this connection to another thread. */
typedef struct {
  sqlite3 *db;
  long long account;
  long long run;
} RCCalendarStore;
RCCalendarStore *RCCalendarStoreOpen(const char *, const char *, RCError *);
void RCCalendarStoreClose(RCCalendarStore *);
int RCCalendarStoreSQL(RCCalendarStore *, RCError *, const char *, ...);
int RCCalendarStoreBeginRun(RCCalendarStore *, RCError *);
int RCCalendarStoreCollection(RCCalendarStore *, const RCDAVCollection *, long long *,
                              RCError *);
int RCCalendarStoreSeen(RCCalendarStore *, long long, const char *, const char *, int *,
                        RCError *);
int RCCalendarStoreSave(RCCalendarStore *, long long, const char *, const char *,
                        const unsigned char *, size_t, RCError *);
int RCCalendarStoreFinishRun(RCCalendarStore *, int, const char *, RCError *);
char *RCCalendarStoreIdentity(RCCalendarStore *, const char *, const char *, RCError *);
#endif
