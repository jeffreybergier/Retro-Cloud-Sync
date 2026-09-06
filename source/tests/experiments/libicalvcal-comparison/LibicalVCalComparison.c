/* Compare the current parser and unmodified libicalvcal on valid vCard 3.0
   input. Keep this opt-in: a failed candidate must not replace production. */
#include "RCVCard.h"
#include "vcc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

typedef struct {
  const char *name;
  const char *body;
  const char *property;
  const char *child;
  int component;
  const char *expected;
} RCCompatibilityCase;

static const RCCompatibilityCase cases[] = {
  { "plain name", "N:Smith;Alice;;;\r\n", "N", VCGivenNameProp,
    1, "Alice" },
  { "UTF-8 name", "N:Fixture;Renée;;;\r\n", "N", VCGivenNameProp,
    1, "Renée" },
  { "Apple property group", "item1.EMAIL;TYPE=HOME:a@example.test\r\n",
    "EMAIL", VCGroupingProp, -1, "item1" },
  { "unquoted types", "EMAIL;TYPE=INTERNET,HOME:a@example.test\r\n",
    "EMAIL", "TYPE", -1, "INTERNET,HOME" },
  { "folded note", "NOTE:Hello\r\n World\r\n", "NOTE", NULL,
    -1, "HelloWorld" },
  { "escaped surname separator", "N:Smith\\;Jones;Alice;;;\r\n",
    "N", VCFamilyNameProp, 0, "Smith;Jones" },
  { "given name after escaped separator", "N:Smith\\;Jones;Alice;;;\r\n",
    "N", VCGivenNameProp, 1, "Alice" },
  { "quoted types", "EMAIL;TYPE=\"HOME,INTERNET\":a@example.test\r\n",
    "EMAIL", "TYPE", -1, "HOME,INTERNET" },
  { "empty note", "NOTE:\r\nTEL:123\r\n", "NOTE", NULL, -1, "" },
  { "phone after empty note", "NOTE:\r\nTEL:123\r\n", "TEL", NULL,
    -1, "123" },
  { "leading value spaces", "NOTE:  Hello\r\n", "NOTE", NULL,
    -1, "  Hello" }
};

static const char *currentValue(const RCVCardDocument *document,
                                const RCCompatibilityCase *test)
{
  size_t i, j;
  for (i = 0; i < document->propertyCount; i++) {
    const RCVCardProperty *property = &document->properties[i];
    if (strcasecmp(property->name, test->property)) continue;
    if (test->component >= 0) {
      for (j = 0; j < property->partCount; j++) {
        if (property->parts[j].component == test->component)
          return property->parts[j].value;
      }
      return NULL;
    }
    if (test->child == NULL) return property->decodedValue;
    if (!strcmp(test->child, VCGroupingProp)) return property->group;
    for (j = 0; j < property->parameterCount; j++) {
      if (!strcasecmp(property->parameters[j].name, test->child)) {
        static char joined[256];
        size_t k;
        joined[0] = '\0';
        for (k = j; k < property->parameterCount; k++) {
          if (strcasecmp(property->parameters[k].name, test->child)) continue;
          if (strlen(joined) + strlen(property->parameters[k].value) + 2 >= sizeof(joined))
            return NULL;
          if (joined[0]) strcat(joined, ",");
          strcat(joined, property->parameters[k].value);
        }
        return joined;
      }
    }
    return NULL;
  }
  return NULL;
}

static char *candidateValue(VObject *card, const RCCompatibilityCase *test)
{
  VObject *property = isAPropertyOf(card, test->property);
  if (property != NULL && test->child != NULL)
    property = isAPropertyOf(property, test->child);
  if (property == NULL) return NULL;
  switch (vObjectValueType(property)) {
    case VCVT_USTRINGZ: return fakeCString(vObjectUStringZValue(property));
    case VCVT_STRINGZ: return strdup(vObjectStringZValue(property));
    case VCVT_NOVALUE: return strdup("");
    default: return NULL;
  }
}

int main(void)
{
  size_t i;
  int baselineFailures = 0, candidateFailures = 0;
  for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
    const RCCompatibilityCase *test = &cases[i];
    char input[512];
    RCVCardDocument document;
    RCError error;
    const char *baseline;
    VObject *card;
    char *candidate;
    int length = snprintf(input, sizeof(input),
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:compat\r\nFN:Test\r\n%sEND:VCARD\r\n",
        test->body);
    if (length < 0 || (size_t)length >= sizeof(input)) return 2;
    if (!RCVCardParse((const unsigned char *)input, (size_t)length,
                       &document, &error)) {
      fprintf(stderr, "Current parser rejected %s: %s\n", test->name,
              error.message);
      baselineFailures++;
    } else {
      baseline = currentValue(&document, test);
      if (baseline == NULL || strcmp(baseline, test->expected)) {
        fprintf(stderr, "Current parser failed %s\n", test->name);
        baselineFailures++;
      }
    }
    RCVCardDocumentClear(&document);

    card = Parse_MIME(input, (unsigned long)length);
    candidate = card == NULL ? NULL : candidateValue(card, test);
    if (candidate == NULL || strcmp(candidate, test->expected)) {
      printf("FAIL libicalvcal: %s: expected [%s], got [%s]\n",
             test->name, test->expected,
             card == NULL ? "card rejected" :
             candidate == NULL ? "property missing" : candidate);
      candidateFailures++;
    } else {
      printf("PASS libicalvcal: %s\n", test->name);
    }
    free(candidate);
    cleanVObjects(card);
    cleanStrTbl();
  }
  printf("%lu cases: current parser %d failures; libicalvcal %d failures.\n",
         (unsigned long)(sizeof(cases) / sizeof(cases[0])),
         baselineFailures, candidateFailures);
  return baselineFailures != 0 || candidateFailures != 0;
}
