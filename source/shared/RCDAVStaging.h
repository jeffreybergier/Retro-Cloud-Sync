#ifndef RC_DAV_STAGING_H
#define RC_DAV_STAGING_H
#include "RCError.h"
#include <AltivecCore/sqlite3.h>
#include <stddef.h>

enum { RCDAVStageSeen, RCDAVStageDownloaded, RCDAVStageDeleted };
/* A private temporary database bounds memory while downloading. Every statement
   finishes before returning; no transaction spans a network request. Closing the
   connection discards the staging file, including on failed inventories. */
sqlite3 *RCDAVStageOpen(RCError *);
int RCDAVStageReset(sqlite3 *, long long collection, RCError *);
int RCDAVStageHasResource(sqlite3 *, long long collection, const char *href,
                          int *present, RCError *);
int RCDAVStageSave(sqlite3 *, long long collection, int action, const char *href,
                   const char *etag, const void *body, size_t length, RCError *);
typedef int (*RCDAVStageCallback)(int action, const char *href, const char *etag,
    const unsigned char *body, size_t length, void *context, RCError *);
int RCDAVStageApply(sqlite3 *, long long collection, RCDAVStageCallback,
                    void *context, RCError *);
/* Read-only lookup, scoped to the mirror account and collection URL. */
int RCDAVMirrorResourceCurrent(sqlite3 *, long long account, int calendar,
    const char *collection, const char *href, const char *etag, int *, RCError *);
#endif
