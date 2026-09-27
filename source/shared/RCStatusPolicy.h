#ifndef RC_STATUS_POLICY_H
#define RC_STATUS_POLICY_H
#include "RCWriteJournal.h"
typedef struct {
  long pending;
  int known, advanceSuccess;
  const char *phase, *severity;
} RCStatusResult;
/* Query only this account. Missing optional tables are empty; failed queries
   are unknown and cannot advance success. Persistence remains platform-owned. */
RCStatusResult RCStatusEvaluate(RCWriteJournal *, int contacts, int complete,
    int failed, int stopping);
#endif
