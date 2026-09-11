#ifndef RC_RESOURCE_PATCH_H
#define RC_RESOURCE_PATCH_H
#include "RCError.h"
#include "RCWriteJournal.h"
#include <stddef.h>

typedef enum { RCResourceVCard, RCResourceCalendar } RCResourceFormat;
typedef struct {
  /* BEGIN components numbered in source order, starting at zero. Contacts have
     component 0; calendar edits target an exact VEVENT/VALARM in the base body,
     so detached instances and unrelated alarms are never regenerated. */
  size_t component;
  const char *property;
  const char *group; /* NULL means ungrouped. */
  int occurrence; /* zero-based among matching properties; -1 appends. */
  /* Encoded property value (vCard/iCalendar escaping), not a content line.
     NULL removes an existing property. Parameters are retained unless overridden. */
  const char *value;
  /* Explicit full parameter replacement, e.g. TYPE=HOME,PREF. NULL retains
     existing parameters; an empty string removes them. The caller owns lossless
     reconstruction and round-trip validation when overriding parameters. */
  const char *parameters;
  /* Optional output group for an existing vCard property; selector is unchanged. */
  const char *replacementGroup;
  /* Explicit rename between writable properties, e.g. X-AIM to IMPP. */
  const char *replacementProperty;
} RCResourceEdit;

/* All selectors address the same immutable base, including multiple deletions.
   Only mapped value fields are editable; structural identity properties cannot
   change. Unknown fields/parameters and untouched physical lines are preserved.
   Parameter changes must be explicit; this function does not infer them. Caller frees output. */
int RCResourcePatch(RCResourceFormat, const unsigned char *base, size_t length,
    const RCResourceEdit *, size_t editCount, unsigned char **output,
    size_t *outputLength, RCError *);
/* Patch the published base (or the same change's journaled base on replay),
   then atomically pin it and the intended bytes in the outbox. */
int RCResourceEnqueueEdits(RCWriteJournal *, const char *changeID,
    const char *resourceKey, long long localRevision, RCResourceFormat,
    const RCResourceEdit *, size_t editCount, long long *operationID, RCError *);
#endif
