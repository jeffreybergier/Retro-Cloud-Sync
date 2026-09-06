#include "RCContactStore.h"
#include "RCVCard.h"

#include <AltivecCore/sqlite3.h>
#include <stdio.h>
#include <string.h>

static const unsigned char kRCInitialAlpha[] =
    "BEGIN:VCARD\r\n"
    "VERSION:3.0\r\n"
    "UID:retrocloud-syncservices-test-alpha\r\n"
    "N:Fixture;RCSSTestAlpha;Renée;Dr.;Jr.\r\n"
    "FN:RCSSTestAlpha Fixture\r\n"
    "ORG:Retro Cloud Test;Initial\r\n"
    "TITLE:Initial Tester\r\n"
    "NICKNAME:Étoile\r\n"
    "NOTE:Première ligne\\n東京\r\n"
    "BDAY:2001-02-03\r\n"
    "TEL;TYPE=HOME:+1-555-0102\r\n"
    "item1.TEL;TYPE=CELL,PREF:+1-555-0101\r\n"
    "item1.X-ABLabel:Test Mobile\r\n"
    "EMAIL;TYPE=HOME:second-alpha@retrocloudsync.invalid\r\n"
    "EMAIL;TYPE=WORK,PREF:initial-alpha@retrocloudsync.invalid\r\n"
    "item2.ADR;TYPE=WORK:;;1 Static Way;Testville;CA;90001;USA\r\n"
    "item2.X-ABADR:us\r\n"
    "URL;TYPE=WORK:https://initial.invalid/alpha\r\n"
    "END:VCARD\r\n";

static const unsigned char kRCUpdatedAlpha[] =
    "BEGIN:VCARD\r\n"
    "VERSION:3.0\r\n"
    "UID:retrocloud-syncservices-test-alpha\r\n"
    "N:Fixture;RCSSTestAlpha;;;\r\n"
    "FN:RCSSTestAlpha Fixture\r\n"
    "ORG:Retro Cloud Test;Updated\r\n"
    "TITLE:Updated Tester\r\n"
    "BDAY:2001-02-03\r\n"
    "TEL;TYPE=CELL,PREF:+1-555-0199\r\n"
    "EMAIL;TYPE=WORK,PREF:updated-alpha@retrocloudsync.invalid\r\n"
    "ADR;TYPE=WORK:;;99 Changed Road;New Testville;NY;10001;USA\r\n"
    "URL;TYPE=WORK:https://updated.invalid/alpha\r\n"
    "END:VCARD\r\n";

static const unsigned char kRCStrippedAlpha[] =
    "BEGIN:VCARD\r\nVERSION:3.0\r\n"
    "UID:retrocloud-syncservices-test-alpha\r\n"
    "N:Fixture;RCSSTestAlpha;;;\r\n"
    "FN:RCSSTestAlpha Fixture\r\nEND:VCARD\r\n";

/* Same content, reversed property order: child identity must not cause stale
   or duplicate values when a server rewrites a vCard. */
static void RCReverseProperties(unsigned char *output)
{
  const char *body = (const char *)kRCInitialAlpha;
  const char *starts[64];
  size_t lengths[64], count = 0;
  const char *line = body + strlen("BEGIN:VCARD\r\nVERSION:3.0\r\n");
  strcpy((char *)output, "BEGIN:VCARD\r\nVERSION:3.0\r\n");
  while (strncmp(line, "END:VCARD", 9)) {
    const char *end = strstr(line, "\r\n");
    starts[count] = line;
    lengths[count++] = (size_t)(end + 2 - line);
    line = end + 2;
  }
  while (count) {
    --count;
    strncat((char *)output, starts[count], lengths[count]);
  }
  strcat((char *)output, "END:VCARD\r\n");
}

static const unsigned char kRCInitialBeta[] =
    "BEGIN:VCARD\r\n"
    "VERSION:3.0\r\n"
    "UID:retrocloud-syncservices-test-beta\r\n"
    "N:Fixture;RCSSTestBeta;;;\r\n"
    "FN:RCSSTestBeta Fixture\r\n"
    "ORG:Retro Cloud Test Company\r\n"
    "X-ABShowAs:COMPANY\r\n"
    "EMAIL;TYPE=HOME:beta@retrocloudsync.invalid\r\n"
    "END:VCARD\r\n";

static int RCSaveVCard(RCContactStore *store, long long collectionIdentifier,
                       long long runIdentifier, const char *href,
                       const char *etag, const unsigned char *vcard,
                       size_t length, RCError *error)
{
  RCVCardDocument document;
  int result;

  RCVCardDocumentInit(&document);
  if (!RCVCardParse(vcard, length, &document, error)) return 0;
  result = RCContactStoreSaveVCard(store, collectionIdentifier, runIdentifier,
      href, etag, vcard, length, &document, error);
  RCVCardDocumentClear(&document);
  return result;
}

int main(int argc, char *argv[])
{
  RCContactStore *store = NULL;
  RCError error;
  long long collectionIdentifier;
  long long runIdentifier;
  int isInitial;
  int isUpdated;
  int isEmpty;
  int isReordered;
  int isStripped;
  int isMalformed;
  int isMissingIdentity;
  int isRetained;
  int isInterrupted;
  int isFresh;
  unsigned char reordered[sizeof(kRCInitialAlpha)];
  int success = 0;

  if (argc != 3) {
    fprintf(stderr, "usage: %s initial|reordered|updated|stripped|malformed|missing-identity|empty DATABASE\n", argv[0]);
    return 2;
  }
  isInitial = strcmp(argv[1], "initial") == 0;
  isUpdated = strcmp(argv[1], "updated") == 0;
  isEmpty = strcmp(argv[1], "empty") == 0;
  isReordered = strcmp(argv[1], "reordered") == 0;
  isStripped = strcmp(argv[1], "stripped") == 0;
  isMalformed = strcmp(argv[1], "malformed") == 0;
  isMissingIdentity = strcmp(argv[1], "missing-identity") == 0;
  isRetained = strcmp(argv[1], "retained") == 0;
  isInterrupted = strcmp(argv[1], "interrupted") == 0;
  isFresh = strcmp(argv[1], "fresh") == 0;
  if (!isInitial && !isUpdated && !isEmpty && !isReordered &&
      !isStripped && !isMalformed && !isMissingIdentity &&
      !isRetained && !isInterrupted && !isFresh) {
    fprintf(stderr, "Unknown fixture phase: %s\n", argv[1]);
    return 2;
  }

  RCErrorClear(&error);
  store = RCContactStoreOpen(argv[2], "syncservices-test", &error);
  if (isFresh) { success = store != NULL; goto finished; }
  if (store == NULL ||
      !RCContactStoreBeginRun(store, &runIdentifier, &error) ||
      !RCContactStoreGetCollection(store,
          "https://syncservices-test.invalid/addressbook/", "Test Contacts",
          &collectionIdentifier, &error)) goto finished;

  RCReverseProperties(reordered);
  if (isInitial || isReordered || isMalformed || isMissingIdentity || isRetained) {
    if (!RCSaveVCard(store, collectionIdentifier, runIdentifier,
            "https://syncservices-test.invalid/addressbook/alpha.vcf",
            "\"initial-alpha\"", isReordered ? reordered : kRCInitialAlpha,
            sizeof(kRCInitialAlpha) - 1, &error) ||
        !RCSaveVCard(store, collectionIdentifier, runIdentifier,
            "https://syncservices-test.invalid/addressbook/beta.vcf",
            "\"initial-beta\"", kRCInitialBeta,
            sizeof(kRCInitialBeta) - 1, &error)) goto finished;
  } else if (isUpdated || isStripped || isInterrupted) {
    if (!RCSaveVCard(store, collectionIdentifier, runIdentifier,
            "https://syncservices-test.invalid/addressbook/alpha.vcf",
            "\"updated-alpha\"", isStripped ? kRCStrippedAlpha : kRCUpdatedAlpha,
            isStripped ? sizeof(kRCStrippedAlpha) - 1 : sizeof(kRCUpdatedAlpha) - 1, &error)) goto finished;
  }

  if (isRetained) {
    int parseFailed;
    const unsigned char invalid[] = "invalid remote replacement";
    if (!RCContactStoreSaveResource(store, collectionIdentifier, runIdentifier,
          "https://syncservices-test.invalid/addressbook/alpha.vcf", "invalid",
          invalid, sizeof(invalid) - 1, &parseFailed, &error) || !parseFailed ||
        !RCContactStoreSaveResource(store, collectionIdentifier, runIdentifier,
          "https://syncservices-test.invalid/addressbook/new.vcf", "invalid",
          invalid, sizeof(invalid) - 1, &parseFailed, &error) || !parseFailed)
      goto finished;
  }

  if (!RCContactStoreFinishCollection(store, collectionIdentifier,
          runIdentifier, &error) ||
      !RCContactStoreFinishRun(store, runIdentifier, !isInterrupted,
          isInterrupted ? "Simulated failed network inventory" : NULL, &error)) {
    goto finished;
  }
  if (isMalformed || isMissingIdentity) {
    sqlite3 *database = NULL;
    int result;
    RCContactStoreClose(store);
    store = NULL;
    result = sqlite3_open(argv[2], &database);
    if (result == SQLITE_OK) result = sqlite3_exec(database,
        "UPDATE contacts SET usable_vcard=replace(CAST(usable_vcard AS TEXT),"
        "'Initial','Uncommitted') WHERE given_name='RCSSTestAlpha';",
        NULL, NULL, NULL);
    if (result == SQLITE_OK) result = sqlite3_exec(database, isMalformed ?
        "UPDATE contacts SET usable_vcard='invalid vCard' WHERE given_name='RCSSTestBeta';" :
        "UPDATE contact_properties SET sync_record_id=NULL WHERE property_name='EMAIL' "
        "AND contact_id=(SELECT id FROM contacts WHERE given_name='RCSSTestBeta');",
        NULL, NULL, NULL);
    if (result != SQLITE_OK) RCErrorSet(&error, result, "Could not corrupt synthetic fixture");
    sqlite3_close(database);
    if (result != SQLITE_OK) goto finished;
  }
  success = 1;

finished:
  if (!success) {
    fprintf(stderr, "Could not create %s fixture: %s\n", argv[1],
            error.message[0] != '\0' ? error.message : "unknown error");
  }
  RCContactStoreClose(store);
  return success ? 0 : 1;
}
