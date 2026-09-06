/* libvc owns content-line and parameter parsing. This adapter unfolds input,
   decodes text/structured values, and maps them to the stored contact model. */
#ifndef __APPLE__
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif
#include "RCVCard.h"
#include "vc.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
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

static int RCMapProperty(vc_component *component, int position,
                          RCVCardDocument *document, RCError *error)
{
  RCVCardProperty *properties = realloc(document->properties,
      (document->propertyCount + 1) * sizeof(*properties));
  RCVCardProperty *property;
  vc_component_param *parameter;
  const char *value = vc_get_value(component);
  int parameterPosition = 0;
  if (properties == NULL) {
    RCErrorSet(error, 1, "Out of memory mapping libvc properties");
    return 0;
  }
  document->properties = properties;
  property = &properties[document->propertyCount++];
  memset(property, 0, sizeof(*property));
  property->position = position;
  property->group = RCCopyString(vc_get_group(component));
  property->name = RCCopyString(vc_get_name(component));
  property->originalValue = RCCopyString(value == NULL ? "" : value);
  property->decodedValue = RCDecodeValue(value == NULL ? "" : value,
                                        value == NULL ? 0 : strlen(value));
  if (property->name == NULL || property->originalValue == NULL ||
      property->decodedValue == NULL ||
      (vc_get_group(component) != NULL && property->group == NULL)) {
    RCErrorSet(error, 1, "Out of memory mapping libvc property");
    return 0;
  }
  for (parameter = vc_get_param(component); parameter != NULL;
       parameter = vc_param_get_next(parameter)) {
    const char *name = vc_param_get_name(parameter);
    const char *parameterValue = vc_param_get_value(parameter);
    if (name == NULL || parameterValue == NULL ||
        !RCAddParameter(property, name, parameterValue, parameterPosition++)) {
      RCErrorSet(error, 1, "Unable to map libvc parameter");
      return 0;
    }
    if (!strcasecmp(name, "VALUE") && property->valueType == NULL) {
      property->valueType = RCCopyString(parameterValue);
      if (property->valueType == NULL) return 0;
    }
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

/* libvc's generated parser and scanner use process-global state. */
static pthread_mutex_t RCParserMutex = PTHREAD_MUTEX_INITIALIZER;

#ifdef __APPLE__
typedef struct {
  const char *bytes;
  size_t length;
  size_t position;
} RCVCardInput;

static int RCReadInput(void *cookie, char *buffer, int count)
{
  RCVCardInput *input = cookie;
  size_t amount = input->length - input->position;
  if (count <= 0) return 0;
  if (amount > (size_t)count) amount = (size_t)count;
  memcpy(buffer, input->bytes + input->position, amount);
  input->position += amount;
  return (int)amount;
}

static fpos_t RCSeekInput(void *cookie, fpos_t offset, int whence)
{
  RCVCardInput *input = cookie;
  fpos_t base;
  switch (whence) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = (fpos_t)input->position; break;
    case SEEK_END: base = (fpos_t)input->length; break;
    default: errno = EINVAL; return (fpos_t)-1;
  }
  if (offset < -base || offset > (fpos_t)input->length - base) {
    errno = EINVAL;
    return (fpos_t)-1;
  }
  input->position = (size_t)(base + offset);
  return base + offset;
}
#endif

int RCVCardParse(const unsigned char *bytes, size_t length,
                 RCVCardDocument *document, RCError *error)
{
  char *unfolded = NULL;
  FILE *input = NULL;
  vc_component *card = NULL, *component;
  int position = 0, result = 0;
  size_t unfoldedLength;
  int trailing;
#ifdef __APPLE__
  RCVCardInput memory;
#endif
  RCErrorClear(error);
  RCVCardDocumentInit(document);
  /* flex and libvc's position tracking use int/long-sized buffers. */
  if (bytes == NULL || length == 0 || length > INT_MAX - 2 ||
      memchr(bytes, 0, length) != NULL ||
      !RCUnfold(bytes, length, &unfolded, error)) goto done;
  unfoldedLength = strlen(unfolded);
#ifdef __APPLE__
  memory.bytes = unfolded;
  memory.length = unfoldedLength;
  memory.position = 0;
  input = funopen(&memory, RCReadInput, NULL, RCSeekInput, NULL);
#else
  input = fmemopen(unfolded, unfoldedLength, "r");
#endif
  if (input == NULL) {
    RCErrorSet(error, 1, "Unable to open vCard input stream");
    goto done;
  }
  if (pthread_mutex_lock(&RCParserMutex) != 0) {
    RCErrorSet(error, 1, "Unable to lock vCard parser");
    goto done;
  }
  card = parse_vcard_file(input);
  pthread_mutex_unlock(&RCParserMutex);
  if (card == NULL) goto done;
  /* A CardDAV resource must contain exactly one card. */
  while ((trailing = fgetc(input)) != EOF) {
    if (trailing != '\r' && trailing != '\n' && trailing != ' ' && trailing != '\t')
      goto done;
  }
  if (ferror(input)) goto done;
  for (component = vc_get_next(card); component != NULL;
       component = vc_get_next(component)) {
    if (!RCMapProperty(component, position++, document, error)) goto done;
  }
  result = 1;
done:
  vc_delete_deep(card);
  if (input != NULL) fclose(input);
  free(unfolded);
  if (!result) {
    RCVCardDocumentClear(document);
    if (error == NULL || error->code == 0)
      RCErrorSet(error, 1, "Response is not a complete vCard");
  }
  return result;
}
