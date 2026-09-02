#include "RCVCard.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static char *RCCopyRange(const char *start, size_t length)
{
  char *result = (char *)malloc(length + 1);
  if (result != NULL) {
    memcpy(result, start, length);
    result[length] = '\0';
  }
  return result;
}

static char *RCCopyString(const char *value)
{
  return value == NULL ? NULL : RCCopyRange(value, strlen(value));
}

static char *RCDecodeValue(const char *value, size_t length)
{
  char *decoded = (char *)malloc(length + 1);
  size_t source = 0;
  size_t destination = 0;

  if (decoded == NULL) {
    return NULL;
  }
  while (source < length) {
    if (value[source] == '\\' && source + 1 < length) {
      char escaped = value[++source];
      if (escaped == 'n' || escaped == 'N') {
        decoded[destination++] = '\n';
      } else {
        decoded[destination++] = escaped;
      }
      source++;
    } else {
      decoded[destination++] = value[source++];
    }
  }
  decoded[destination] = '\0';
  return decoded;
}

static int RCAppendBytes(char **buffer, size_t *length, size_t *capacity,
                         const char *bytes, size_t byteCount)
{
  size_t required = *length + byteCount + 1;
  char *newBuffer;

  if (required > *capacity) {
    size_t newCapacity = *capacity == 0 ? 1024 : *capacity;
    while (newCapacity < required) {
      if (newCapacity > ((size_t)-1) / 2) {
        return 0;
      }
      newCapacity *= 2;
    }
    newBuffer = (char *)realloc(*buffer, newCapacity);
    if (newBuffer == NULL) {
      return 0;
    }
    *buffer = newBuffer;
    *capacity = newCapacity;
  }
  memcpy(*buffer + *length, bytes, byteCount);
  *length += byteCount;
  (*buffer)[*length] = '\0';
  return 1;
}

static int RCUnfold(const unsigned char *bytes, size_t length,
                    char **unfolded, RCError *error)
{
  size_t source = 0;
  size_t outputLength = 0;
  size_t capacity = 0;
  char *output = NULL;

  while (source < length) {
    size_t lineStart = source;
    size_t lineLength;

    while (source < length && bytes[source] != '\r' && bytes[source] != '\n') {
      source++;
    }
    lineLength = source - lineStart;
    if (!RCAppendBytes(&output, &outputLength, &capacity,
                       (const char *)bytes + lineStart, lineLength)) {
      free(output);
      RCErrorSet(error, 1, "Out of memory unfolding vCard");
      return 0;
    }
    if (source < length && bytes[source] == '\r') {
      source++;
    }
    if (source < length && bytes[source] == '\n') {
      source++;
    }
    if (source < length && (bytes[source] == ' ' || bytes[source] == '\t')) {
      source++;
    } else if (!RCAppendBytes(&output, &outputLength, &capacity, "\n", 1)) {
      free(output);
      RCErrorSet(error, 1, "Out of memory unfolding vCard");
      return 0;
    }
  }
  *unfolded = output;
  return 1;
}

static char *RCFindUnquoted(char *text, char character)
{
  int quoted = 0;
  int escaped = 0;

  while (*text != '\0') {
    if (escaped) {
      escaped = 0;
    } else if (*text == '\\') {
      escaped = 1;
    } else if (*text == '"') {
      quoted = !quoted;
    } else if (*text == character && !quoted) {
      return text;
    }
    text++;
  }
  return NULL;
}

static int RCAddParameter(RCVCardProperty *property, const char *name,
                          const char *value, int position)
{
  RCVCardParameter *parameters = (RCVCardParameter *)realloc(
      property->parameters,
      (property->parameterCount + 1) * sizeof(*parameters));
  RCVCardParameter *parameter;

  if (parameters == NULL) {
    return 0;
  }
  property->parameters = parameters;
  parameter = &parameters[property->parameterCount++];
  parameter->name = RCCopyString(name);
  parameter->value = RCCopyString(value);
  parameter->position = position;
  return parameter->name != NULL && parameter->value != NULL;
}

static int RCAddPart(RCVCardProperty *property, const char *value,
                     size_t length, int component, int position)
{
  RCVCardValuePart *parts = (RCVCardValuePart *)realloc(
      property->parts, (property->partCount + 1) * sizeof(*parts));
  RCVCardValuePart *part;

  if (parts == NULL) {
    return 0;
  }
  property->parts = parts;
  part = &parts[property->partCount++];
  part->value = RCDecodeValue(value, length);
  part->component = component;
  part->position = position;
  return part->value != NULL;
}

static int RCParseParts(RCVCardProperty *property)
{
  const char *start = property->originalValue;
  const char *cursor = start;
  int escaped = 0;
  int component = 0;

  if (strcasecmp(property->name, "N") != 0 &&
      strcasecmp(property->name, "ADR") != 0 &&
      strcasecmp(property->name, "ORG") != 0) {
    return 1;
  }
  for (;;) {
    if (*cursor == '\0' || (*cursor == ';' && !escaped)) {
      if (!RCAddPart(property, start, (size_t)(cursor - start),
                     component, 0)) {
        return 0;
      }
      if (*cursor == '\0') {
        break;
      }
      component++;
      start = cursor + 1;
    }
    if (*cursor == '\0') {
      break;
    }
    if (escaped) {
      escaped = 0;
    } else if (*cursor == '\\') {
      escaped = 1;
    }
    cursor++;
  }
  return 1;
}

static void RCSetProjection(char **field, const char *value)
{
  if (*field == NULL) {
    *field = RCCopyString(value);
  }
}

static int RCParseProperty(char *line, int position,
                           RCVCardDocument *document, RCError *error)
{
  char *colon = RCFindUnquoted(line, ':');
  char *header;
  char *nameEnd;
  char *dot;
  RCVCardProperty *properties;
  RCVCardProperty *property;
  char *parameterCursor;
  int parameterPosition = 0;

  if (colon == NULL) {
    return 1;
  }
  *colon = '\0';
  header = line;
  properties = (RCVCardProperty *)realloc(
      document->properties,
      (document->propertyCount + 1) * sizeof(*properties));
  if (properties == NULL) {
    RCErrorSet(error, 1, "Out of memory parsing vCard properties");
    return 0;
  }
  document->properties = properties;
  property = &properties[document->propertyCount++];
  memset(property, 0, sizeof(*property));
  property->position = position;
  property->originalValue = RCCopyString(colon + 1);
  property->decodedValue = RCDecodeValue(colon + 1, strlen(colon + 1));

  nameEnd = RCFindUnquoted(header, ';');
  if (nameEnd != NULL) {
    *nameEnd = '\0';
    parameterCursor = nameEnd + 1;
  } else {
    parameterCursor = NULL;
  }
  dot = strchr(header, '.');
  if (dot != NULL) {
    *dot = '\0';
    property->group = RCCopyString(header);
    property->name = RCCopyString(dot + 1);
  } else {
    property->name = RCCopyString(header);
  }
  if (property->name == NULL || property->originalValue == NULL ||
      property->decodedValue == NULL) {
    RCErrorSet(error, 1, "Out of memory parsing vCard property");
    return 0;
  }

  while (parameterCursor != NULL && *parameterCursor != '\0') {
    char *next = RCFindUnquoted(parameterCursor, ';');
    char *equals;
    if (next != NULL) {
      *next = '\0';
    }
    equals = RCFindUnquoted(parameterCursor, '=');
    if (equals != NULL) {
      char *value;
      *equals = '\0';
      value = equals + 1;
      if (value[0] == '"' && value[strlen(value) - 1] == '"' &&
          strlen(value) >= 2) {
        value[strlen(value) - 1] = '\0';
        value++;
      }
      if (!RCAddParameter(property, parameterCursor, value,
                          parameterPosition++)) {
        RCErrorSet(error, 1, "Out of memory parsing vCard parameter");
        return 0;
      }
      if (strcasecmp(parameterCursor, "VALUE") == 0) {
        property->valueType = RCCopyString(value);
      }
    } else if (!RCAddParameter(property, "TYPE", parameterCursor,
                               parameterPosition++)) {
      RCErrorSet(error, 1, "Out of memory parsing vCard parameter");
      return 0;
    }
    parameterCursor = next == NULL ? NULL : next + 1;
  }
  if (!RCParseParts(property)) {
    RCErrorSet(error, 1, "Out of memory parsing structured vCard value");
    return 0;
  }

  if (strcasecmp(property->name, "VERSION") == 0) {
    RCSetProjection(&document->version, property->decodedValue);
  } else if (strcasecmp(property->name, "UID") == 0) {
    RCSetProjection(&document->uid, property->decodedValue);
  } else if (strcasecmp(property->name, "FN") == 0) {
    RCSetProjection(&document->formattedName, property->decodedValue);
  } else if (strcasecmp(property->name, "N") == 0) {
    if (property->partCount > 0) RCSetProjection(&document->familyName,
                                                 property->parts[0].value);
    if (property->partCount > 1) RCSetProjection(&document->givenName,
                                                 property->parts[1].value);
  } else if (strcasecmp(property->name, "ORG") == 0) {
    RCSetProjection(&document->organization, property->partCount > 0 ?
                    property->parts[0].value : property->decodedValue);
  } else if (strcasecmp(property->name, "TITLE") == 0) {
    RCSetProjection(&document->title, property->decodedValue);
  } else if (strcasecmp(property->name, "BDAY") == 0) {
    RCSetProjection(&document->birthday, property->decodedValue);
  }
  return 1;
}

void RCVCardDocumentInit(RCVCardDocument *document)
{
  memset(document, 0, sizeof(*document));
}

void RCVCardDocumentClear(RCVCardDocument *document)
{
  size_t propertyIndex;

  if (document == NULL) return;
  for (propertyIndex = 0; propertyIndex < document->propertyCount;
       propertyIndex++) {
    RCVCardProperty *property = &document->properties[propertyIndex];
    size_t index;
    free(property->group);
    free(property->name);
    free(property->decodedValue);
    free(property->originalValue);
    free(property->valueType);
    for (index = 0; index < property->parameterCount; index++) {
      free(property->parameters[index].name);
      free(property->parameters[index].value);
    }
    for (index = 0; index < property->partCount; index++) {
      free(property->parts[index].value);
    }
    free(property->parameters);
    free(property->parts);
  }
  free(document->properties);
  free(document->version);
  free(document->uid);
  free(document->formattedName);
  free(document->givenName);
  free(document->familyName);
  free(document->organization);
  free(document->title);
  free(document->birthday);
  RCVCardDocumentInit(document);
}

int RCVCardParse(const unsigned char *bytes, size_t length,
                 RCVCardDocument *document, RCError *error)
{
  char *unfolded = NULL;
  char *line;
  int position = 0;
  int sawBegin = 0;
  int sawEnd = 0;

  RCErrorClear(error);
  RCVCardDocumentInit(document);
  if (bytes == NULL || length == 0 || !RCUnfold(bytes, length, &unfolded, error)) {
    if (error != NULL && error->code == 0) RCErrorSet(error, 1, "Empty vCard");
    return 0;
  }
  line = unfolded;
  while (line != NULL && *line != '\0') {
    char *next = strchr(line, '\n');
    if (next != NULL) *next = '\0';
    if (strcasecmp(line, "BEGIN:VCARD") == 0) {
      sawBegin = 1;
    } else if (strcasecmp(line, "END:VCARD") == 0) {
      sawEnd = 1;
    } else if (*line != '\0' && !RCParseProperty(line, position++, document,
                                                  error)) {
      free(unfolded);
      RCVCardDocumentClear(document);
      return 0;
    }
    line = next == NULL ? NULL : next + 1;
  }
  free(unfolded);
  if (!sawBegin || !sawEnd) {
    RCVCardDocumentClear(document);
    RCErrorSet(error, 1, "Response is not a complete vCard");
    return 0;
  }
  return 1;
}
