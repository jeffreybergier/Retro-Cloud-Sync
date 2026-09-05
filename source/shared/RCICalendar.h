#ifndef RC_ICALENDAR_H
#define RC_ICALENDAR_H
#include "RCError.h"
#include <libical/ical.h>
#include <stddef.h>
/* Returned trees belong to the caller. Original bytes are retained by the store. */
icalcomponent *RCICalendarParse(const unsigned char *, size_t, RCError *);
const char *RCICalendarValue(icalcomponent *, icalproperty_kind);
/* Caller frees the typed recurrence identity. Empty means master. */
char *RCICalendarRecurrenceKey(icalcomponent *);
const char *RCICalendarTZID(icalproperty *);
void RCICalendarFormatTime(struct icaltimetype, char *, size_t);
const char *RCICalendarTimeKind(struct icaltimetype, const char *);
#endif
