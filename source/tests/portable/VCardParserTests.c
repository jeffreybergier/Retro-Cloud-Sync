#include "RCVCard.h"
#include <pthread.h>
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
} RCVCardCase;

static const RCVCardCase cases[] = {
  { "lowercase property", "email:a@example.test\r\n", "EMAIL", NULL,
    -1, "a@example.test" },
  { "name range boundaries", "X->@AZ\\^`az{}~:Boundary\r\n",
    "X->@AZ\\^`az{}~", NULL, -1, "Boundary" },
  { "plain name", "N:Smith;Alice;;;\r\n", "N", "G",
    1, "Alice" },
  { "UTF-8 name", "N:Fixture;Renée;;;\r\n", "N", "G",
    1, "Renée" },
  { "Apple property group", "item1.EMAIL;TYPE=HOME:a@example.test\r\n",
    "EMAIL", "Grouping", -1, "item1" },
  { "unquoted types", "EMAIL;TYPE=INTERNET,HOME:a@example.test\r\n",
    "EMAIL", "TYPE", -1, "INTERNET,HOME" },
  { "folded note", "NOTE:Hello\r\n World\r\n", "NOTE", NULL,
    -1, "HelloWorld" },
  { "escaped surname separator", "N:Smith\\;Jones;Alice;;;\r\n",
    "N", "F", 0, "Smith;Jones" },
  { "given name after escaped separator", "N:Smith\\;Jones;Alice;;;\r\n",
    "N", "G", 1, "Alice" },
  { "quoted types", "EMAIL;TYPE=\"HOME,INTERNET\":a@example.test\r\n",
    "EMAIL", "TYPE", -1, "HOME,INTERNET" },
  { "empty note", "NOTE:\r\nTEL:123\r\n", "NOTE", NULL, -1, "" },
  { "phone after empty note", "NOTE:\r\nTEL:123\r\n", "TEL", NULL,
    -1, "123" },
  { "quoted punctuation", "EMAIL;X-LABEL=\"Desk: A; B\":a@example.test\r\n",
    "EMAIL", "X-LABEL", -1, "Desk: A; B" },
  { "Apple label group", "item1.X-ABLabel:Custom\r\n", "X-ABLabel",
    "Grouping", -1, "item1" },
  { "escaped note", "NOTE:One\\nTwo\\, Three\\; Four\r\n", "NOTE", NULL,
    -1, "One\nTwo, Three; Four" },
  { "tab folding", "NOTE:Hello\r\n\tWorld\r\n", "NOTE", NULL,
    -1, "HelloWorld" },
  { "empty quoted parameter", "EMAIL;X-LABEL=\"\":a@example.test\r\n",
    "EMAIL", "X-LABEL", -1, "" },
  { "leading value spaces", "NOTE:  Hello\r\n", "NOTE", NULL,
    -1, "  Hello" }
};

static const char *currentValue(const RCVCardDocument *document,
                                const RCVCardCase *test)
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
    if (!strcmp(test->child, "Grouping")) return property->group;
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

static void *parseRepeatedly(void *context)
{
  int *failures = context;
  int i;
  const char *card = "BEGIN:VCARD\nVERSION:3.0\nN:Family;Thread;;;\n"
                     "FN:Thread\nitem1.EMAIL;TYPE=HOME:a@example.test\nEND:VCARD\n";
  for (i = 0; i < 100; i++) {
    RCVCardDocument document;
    RCError error;
    if (!RCVCardParse((const unsigned char *)card, strlen(card), &document, &error) ||
        document.givenName == NULL || strcmp(document.givenName, "Thread"))
      (*failures)++;
    RCVCardDocumentClear(&document);
  }
  return NULL;
}

int main(void)
{
  size_t i;
  int failures = 0;
  static const char *invalid[] = {
    "not a vCard\n",
    "BEGIN:VCARD\nVERSION:3.0\nFN:Incomplete\n",
    "BEGIN:VCARD\nVERSION:3.0\nEMAIL;TYPE=\"unterminated:a@example.test\nEND:VCARD\n",
    "BEGIN:VCARD\nVERSION:3.0\nitem1.EMAIL;TYPE=\"unterminated:a@example.test\nEND:VCARD\n",
    "BEGIN:VCARD\nVERSION:3.0\nEMAIL;TYPE=HOME;\nEND:VCARD\n",
    "BEGIN:VCARD\nVERSION:3.0\nFN:One\nEND:VCARD\ntrailing garbage\n",
    "BEGIN:VCARD\nVERSION:3.0\nFN:One\nEND:VCARD\n"
    "BEGIN:VCARD\nVERSION:3.0\nFN:Two\nEND:VCARD\n"
  };
  for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
    const RCVCardCase *test = &cases[i];
    char input[512];
    RCVCardDocument document;
    RCError error;
    const char *value;
    int length = snprintf(input, sizeof(input),
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:compat\r\nFN:Test\r\n%sEND:VCARD\r\n",
        test->body);
    if (length < 0 || (size_t)length >= sizeof(input)) return 2;
    if (!RCVCardParse((const unsigned char *)input, (size_t)length,
                       &document, &error)) {
      fprintf(stderr, "FAIL %s: %s\n", test->name, error.message);
      failures++;
    } else {
      value = currentValue(&document, test);
      if (value == NULL || strcmp(value, test->expected)) {
        fprintf(stderr, "FAIL %s: expected [%s], got [%s]\n", test->name,
                test->expected, value == NULL ? "missing" : value);
        failures++;
      }
    }
    RCVCardDocumentClear(&document);
  }
  for (i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
    RCVCardDocument document;
    RCError error;
    const char *good = "BEGIN:VCARD\nVERSION:3.0\nFN:Recovery\nEND:VCARD\n";
    if (RCVCardParse((const unsigned char *)invalid[i], strlen(invalid[i]),
                      &document, &error)) {
      fprintf(stderr, "FAIL accepted malformed card %lu\n", (unsigned long)i);
      failures++;
    } else if (error.code == 0 || strstr(error.message, "not a complete vCard") == NULL) {
      fprintf(stderr, "FAIL malformed-card diagnostic %lu: %s\n",
              (unsigned long)i, error.message);
      failures++;
    }
    RCVCardDocumentClear(&document);
    if (!RCVCardParse((const unsigned char *)good, strlen(good), &document, &error) ||
        document.formattedName == NULL || strcmp(document.formattedName, "Recovery")) {
      fprintf(stderr, "FAIL recovery after malformed card %lu\n", (unsigned long)i);
      failures++;
    }
    RCVCardDocumentClear(&document);
  }
  {
    /* Use a value much longer than libvc's legacy 80-byte structure helper. */
    char large[2048];
    RCVCardDocument document;
    RCError error;
    const char *prefix = "BEGIN:VCARD\nVERSION:3.0\nN:";
    size_t start = strlen(prefix);
    strcpy(large, prefix);
    memset(large + start, 'x', 1024);
    strcpy(large + start + 1024, ";Long;;;\nFN:Long\nEND:VCARD\n");
    if (!RCVCardParse((const unsigned char *)large, strlen(large), &document, &error) ||
        document.familyName == NULL || strlen(document.familyName) != 1024 ||
        document.givenName == NULL || strcmp(document.givenName, "Long")) {
      fprintf(stderr, "FAIL long structured value\n");
      failures++;
    }
    RCVCardDocumentClear(&document);
    large[start] = '\0';
    if (RCVCardParse((const unsigned char *)large, start + 20, &document, &error)) {
      fprintf(stderr, "FAIL embedded NUL accepted\n");
      failures++;
    }
    RCVCardDocumentClear(&document);
  }
  {
    pthread_t threads[4];
    int threadFailures[4] = { 0, 0, 0, 0 };
    size_t started = 0;
    for (i = 0; i < 4; i++) {
      if (pthread_create(&threads[i], NULL, parseRepeatedly, &threadFailures[i])) {
        failures++;
        break;
      }
      started++;
    }
    for (i = 0; i < started; i++) {
      pthread_join(threads[i], NULL);
      failures += threadFailures[i];
    }
  }
  printf("vCard values, groups, parameters, malformed-input recovery and concurrency: %d failures.\n", failures);
  return failures != 0;
}
