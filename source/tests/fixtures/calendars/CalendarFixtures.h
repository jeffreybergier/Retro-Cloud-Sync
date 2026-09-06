#ifndef RC_CALENDAR_FIXTURES_H
#define RC_CALENDAR_FIXTURES_H
#include "RCCalendarStore.h"

/* Populate a synthetic phase while retaining identities in the supplied store. */
int RCCalendarFixturePopulate(RCCalendarStore *store, const char *phase, RCError *error);
#endif
