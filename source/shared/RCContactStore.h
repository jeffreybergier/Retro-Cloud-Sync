#ifndef RC_CONTACT_STORE_H
#define RC_CONTACT_STORE_H

#include "RCError.h"
#include "RCVCard.h"

#include <stddef.h>

typedef struct RCContactStore RCContactStore;

typedef struct {
  long resourceCount;
  long availableCount;
  long missingCount;
} RCContactStoreStatistics;

RCContactStore *RCContactStoreOpen(const char *path, RCError *error);
void RCContactStoreClose(RCContactStore *store);

int RCContactStoreBeginRun(RCContactStore *store, long long *runIdentifier,
                           RCError *error);
int RCContactStoreGetCollection(RCContactStore *store, const char *url,
                                const char *displayName,
                                long long *collectionIdentifier,
                                RCError *error);
int RCContactStoreResourceIsCurrent(RCContactStore *store,
                                    long long collectionIdentifier,
                                    const char *href, const char *etag,
                                    int *isCurrent, RCError *error);
int RCContactStoreMarkSeen(RCContactStore *store,
                           long long collectionIdentifier,
                           const char *href, long long runIdentifier,
                           RCError *error);
int RCContactStoreSaveVCard(RCContactStore *store,
                            long long collectionIdentifier,
                            long long runIdentifier,
                            const char *href, const char *etag,
                            const unsigned char *rawVCard,
                            size_t rawVCardLength,
                            const RCVCardDocument *document,
                            RCError *error);
int RCContactStoreFinishCollection(RCContactStore *store,
                                   long long collectionIdentifier,
                                   long long runIdentifier,
                                   RCError *error);
int RCContactStoreFinishRun(RCContactStore *store, long long runIdentifier,
                            int succeeded, const char *message,
                            RCError *error);
int RCContactStoreGetStatistics(RCContactStore *store,
                                RCContactStoreStatistics *statistics,
                                RCError *error);

#endif
