#ifndef RC_VCARD_H
#define RC_VCARD_H

#include "RCError.h"

#include <stddef.h>

typedef struct {
  char *name;
  char *value;
  int position;
} RCVCardParameter;

typedef struct {
  char *value;
  int component;
  int position;
} RCVCardValuePart;

typedef struct {
  char *group;
  char *name;
  char *decodedValue;
  char *originalValue;
  char *valueType;
  int position;
  RCVCardParameter *parameters;
  size_t parameterCount;
  RCVCardValuePart *parts;
  size_t partCount;
} RCVCardProperty;

typedef struct {
  char *version;
  char *uid;
  char *formattedName;
  char *givenName;
  char *familyName;
  char *organization;
  char *title;
  char *birthday;
  RCVCardProperty *properties;
  size_t propertyCount;
} RCVCardDocument;

void RCVCardDocumentInit(RCVCardDocument *document);
void RCVCardDocumentClear(RCVCardDocument *document);
int RCVCardParse(const unsigned char *bytes, size_t length,
                 RCVCardDocument *document, RCError *error);

#endif
