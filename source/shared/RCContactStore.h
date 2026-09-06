#ifndef RC_CONTACT_STORE_H
#define RC_CONTACT_STORE_H

#include "RCError.h"
#include "RCVCard.h"
#include "RCWriteJournal.h"

#include <stddef.h>

typedef struct RCContactStore RCContactStore;

typedef struct {
  long resourceCount;
  long availableCount;
  long missingCount;
  long parseErrorCount;
} RCContactStoreStatistics;

typedef int (*RCContactStoreContactCallback)(
    long long contactIdentifier, const char *syncRecordIdentifier,
    const unsigned char *rawVCard, size_t rawVCardLength,
    void *context, RCError *error);

RCContactStore *RCContactStoreOpen(const char *path, const char *username,
                                  RCError *error);
void RCContactStoreClose(RCContactStore *store);
int RCContactStoreIsAccount(RCContactStore *store, const char *username);
const char *RCContactStoreSyncIdentifier(RCContactStore *store);
RCWriteJournal RCContactStoreWriteJournal(RCContactStore *store);
int RCContactStoreGetPublicationState(RCContactStore *store,
                                      long long *generation,
                                      long long *publishedGeneration,
                                      RCError *error);
int RCContactStoreMarkPublished(RCContactStore *store, long long generation,
                                RCError *error);

/* One run owns a transaction covering the entire account inventory. Successful
   FinishRun requires complete home discovery and FinishCollection for every
   discovered collection (including empty ones). Failure rolls back the run. */
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
/* Retain downloaded bodies in the run. Invalid replacements retain the last usable
   vCard and its child identities; invalid new resources are not exported. */
int RCContactStoreSaveResource(RCContactStore *store,
                               long long collectionIdentifier,
                               long long runIdentifier,
                               const char *href, const char *etag,
                               const unsigned char *bytes, size_t length,
                               int *parseFailed, RCError *error);
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
int RCContactStoreForEachAvailableContact(
    RCContactStore *store, RCContactStoreContactCallback callback,
    void *context, RCError *error);
int RCContactStoreCopyPropertySyncIdentifier(
    RCContactStore *store, long long contactIdentifier, int propertyPosition,
    char **syncRecordIdentifier, RCError *error);

#endif
