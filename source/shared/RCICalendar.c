#include "RCICalendar.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* libical deliberately repairs incomplete input. Reject unbalanced component
   framing before parsing, so a truncated recurrence set cannot lose exceptions. */
static int RCFraming(const unsigned char *bytes, size_t length)
{
  char stack[32][64];
  size_t offset = 0;
  int depth = 0, roots = 0;
  while (offset < length) {
    size_t start = offset, n;
    const unsigned char *line;
    while (offset < length && bytes[offset] != '\n')
      offset++;
    n = offset - start;
    if (offset < length)
      offset++;
    line = bytes + start;
    if (n && line[n - 1] == '\r')
      n--;
    if (!n)
      continue;
    if (line[0] == ' ' || line[0] == '\t') {
      if (!depth)
        return 0;
      continue;
    }
    if (n > 6 && strncasecmp((const char *)line, "BEGIN:", 6) == 0) {
      if (depth == 32 || n - 6 >= sizeof(stack[0]))
        return 0;
      if (!depth &&
          (roots++ || n != 15 || strncasecmp((const char *)line + 6, "VCALENDAR", 9)))
        return 0;
      memcpy(stack[depth], line + 6, n - 6);
      stack[depth][n - 6] = 0;
      depth++;
    } else if (n > 4 && strncasecmp((const char *)line, "END:", 4) == 0) {
      if (!depth || strlen(stack[depth - 1]) != n - 4 ||
          strncasecmp(stack[depth - 1], (const char *)line + 4, n - 4))
        return 0;
      depth--;
    } else if (!depth)
      return 0;
  }
  return roots == 1 && depth == 0;
}

icalcomponent *RCICalendarParse(const unsigned char *bytes, size_t length,
                                RCError *error)
{
  char *copy;
  icalcomponent *root;
  RCErrorClear(error);
  if (!bytes || !length || length > 32U * 1024U * 1024U || memchr(bytes, 0, length) ||
      !RCFraming(bytes, length)) {
    RCErrorSet(error, 1, "Invalid or incomplete iCalendar component framing");
    return NULL;
  }
  copy = malloc(length + 1);
  if (!copy) {
    RCErrorSet(error, 1, "Out of memory parsing iCalendar");
    return NULL;
  }
  memcpy(copy, bytes, length);
  copy[length] = 0;
  icalerror_set_errors_are_fatal(0);
  root = icalparser_parse_string(copy);
  free(copy);
  if (!root || icalcomponent_isa(root) != ICAL_VCALENDAR_COMPONENT ||
      icalcomponent_count_errors(root)) {
    if (root)
      icalcomponent_free(root);
    RCErrorSet(error, 1, "iCalendar contains invalid properties or values");
    return NULL;
  }
  return root;
}

const char *RCICalendarValue(icalcomponent *component, icalproperty_kind kind)
{
  icalproperty *p = icalcomponent_get_first_property(component, kind);
  icalvalue *v = p ? icalproperty_get_value(p) : NULL;
  if (!v)
    return NULL;
  if (icalvalue_isa(v) == ICAL_TEXT_VALUE)
    return icalvalue_get_text(v);
  return icalproperty_get_value_as_string(p);
}
const char *RCICalendarTZID(icalproperty *p)
{
  icalparameter *param =
      p ? icalproperty_get_first_parameter(p, ICAL_TZID_PARAMETER) : NULL;
  return param ? icalparameter_get_tzid(param) : NULL;
}
char *RCICalendarRecurrenceKey(icalcomponent *component)
{
  icalproperty *p =
      icalcomponent_get_first_property(component, ICAL_RECURRENCEID_PROPERTY);
  const char *value = p ? icalproperty_get_value_as_string(p) : "";
  const char *tz = RCICalendarTZID(p);
  char *key;
  if (!tz)
    tz = "";
  if (!value)
    return NULL;
  key = malloc(strlen(value) + strlen(tz) + 32);
  if (key) {
    if (p)
      snprintf(key, strlen(value) + strlen(tz) + 32, "%s:%s:%s",
               icalvalue_kind_to_string(icalvalue_isa(icalproperty_get_value(p))), tz,
               value);
    else
      key[0] = 0;
  }
  return key;
}
void RCICalendarFormatTime(struct icaltimetype t, char *out, size_t size)
{
  if (icaltime_is_null_time(t)) {
    if (size)
      out[0] = 0;
    return;
  }
  if (t.is_date)
    snprintf(out, size, "%04d-%02d-%02d", t.year, t.month, t.day);
  else
    snprintf(out, size, "%04d-%02d-%02dT%02d:%02d:%02d%s", t.year, t.month, t.day,
             t.hour, t.minute, t.second, icaltime_is_utc(t) ? "Z" : "");
}
const char *RCICalendarTimeKind(struct icaltimetype t, const char *tz)
{
  if (icaltime_is_null_time(t))
    return "missing";
  return t.is_date ? "date" : icaltime_is_utc(t) ? "utc" : tz ? "zoned" : "floating";
}
