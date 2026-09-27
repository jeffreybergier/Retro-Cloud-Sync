#ifndef RC_CALENDAR_PROJECTION_H
#define RC_CALENDAR_PROJECTION_H
#include "RCICalendar.h"
/* Adapter returns the native platform's offset at a UTC instant, or 0 when
   the zone is unknown. All authoritative calculations use the wire VTIMEZONE. */
typedef int (*RCCalendarNativeOffset)(void *, const char *, struct icaltimetype, int *);
icaltimezone *RCCalendarSourceZone(icalcomponent *, icalproperty *);
int RCRecurrenceDay(struct icaltimetype, struct icaltimetype, int *);
int RCExpandFiniteRecurrence(icalcomponent *, RCError *);
int RCSourceZoneIsFixed(icaltimezone *, int);
int RCCalendarNeedsUTCProjection(icalcomponent *, icalcomponent *, RCCalendarNativeOffset, void *);
/* Mutates a disposable parsed tree; callers retain the original wire bytes. */
int RCCalendarPrepareProjection(icalcomponent *, RCCalendarNativeOffset, void *, RCError *);
#endif
