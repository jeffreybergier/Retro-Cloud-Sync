#ifndef RC_SYNC_SERVICES_BRIDGE_H
#define RC_SYNC_SERVICES_BRIDGE_H

#include "RCContactStore.h"
#include "RCError.h"

int RCSyncServicesPushContacts(RCContactStore *store,
                               const char *clientDescriptionPath,
                               long *recordCount, RCError *error);
int RCSyncServicesPushTestContacts(RCContactStore *store,
                                   const char *clientDescriptionPath,
                                   long *recordCount, RCError *error);
int RCSyncServicesUnregisterTestClient(RCError *error);

#endif
