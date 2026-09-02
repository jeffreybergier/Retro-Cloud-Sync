#include "RCContactStore.h"
#include "RCVCard.h"

#include <AltivecCore/sqlite3.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int RCFail(const char *message, const RCError *error)
{
  fprintf(stderr, "FAIL: %s", message);
  if (error != NULL && error->message[0] != '\0') {
    fprintf(stderr, ": %s", error->message);
  }
  fputc('\n', stderr);
  return 1;
}

static int RCScalar(const char *path, const char *sql)
{
  sqlite3 *database = NULL;
  sqlite3_stmt *statement = NULL;
  int value = -1;
  if (sqlite3_open(path, &database) == SQLITE_OK &&
      sqlite3_prepare_v2(database, sql, -1, &statement, NULL) == SQLITE_OK &&
      sqlite3_step(statement) == SQLITE_ROW) {
    value = sqlite3_column_int(statement, 0);
  }
  sqlite3_finalize(statement);
  sqlite3_close(database);
  return value;
}

int main(void)
{
  static const unsigned char vcard[] =
      "BEGIN:VCARD\r\n"
      "VERSION:3.0\r\n"
      "UID:contact-1\r\n"
      "N:Smith;Alice;Marie;Dr.;Jr.\r\n"
      "FN:Alice Smith\r\n"
      "item1.EMAIL;TYPE=INTERNET,HOME:alice@example.com\r\n"
      "item1.X-ABLabel:_$!<Home>!$_\r\n"
      "ADR;TYPE=HOME:;;123 Main St.;Boston;MA;02110;USA\r\n"
      "NOTE:First line\\nSecond line\r\n"
      " X-continued\r\n"
      "X-APPLE-UNKNOWN;VALUE=text:preserve me\r\n"
      "END:VCARD\r\n";
  char path[] = "/tmp/retrocloud-shared-test-XXXXXX";
  int descriptor;
  RCError error;
  RCVCardDocument document;
  RCContactStore *store = NULL;
  RCContactStoreStatistics statistics;
  long long collectionIdentifier;
  long long run;
  int current = 0;
  int status = 1;

  descriptor = mkstemp(path);
  if (descriptor < 0) return RCFail("could not create temporary database", NULL);
  close(descriptor);
  RCErrorClear(&error);
  if (!RCVCardParse(vcard, sizeof(vcard) - 1, &document, &error))
    goto failed_parse;
  if (document.propertyCount < 9 || document.uid == NULL ||
      strcmp(document.uid, "contact-1") != 0 || document.familyName == NULL ||
      strcmp(document.familyName, "Smith") != 0 || document.givenName == NULL ||
      strcmp(document.givenName, "Alice") != 0) {
    RCErrorSet(&error, 1, "vCard projections were not parsed correctly");
    goto failed;
  }
  store = RCContactStoreOpen(path, &error);
  if (store == NULL ||
      !RCContactStoreBeginRun(store, &run, &error) ||
      !RCContactStoreGetCollection(store, "https://example.test/addressbook/",
                                   "Contacts", &collectionIdentifier, &error) ||
      !RCContactStoreSaveVCard(store, collectionIdentifier, run,
          "https://example.test/addressbook/contact-1.vcf", "\"one\"",
          vcard, sizeof(vcard) - 1, &document, &error) ||
      !RCContactStoreFinishCollection(store, collectionIdentifier, run, &error) ||
      !RCContactStoreFinishRun(store, run, 1, NULL, &error) ||
      !RCContactStoreResourceIsCurrent(store, collectionIdentifier,
          "https://example.test/addressbook/contact-1.vcf", "\"one\"",
          &current, &error) || !current) goto failed;

  if (!RCContactStoreBeginRun(store, &run, &error) ||
      !RCContactStoreFinishCollection(store, collectionIdentifier, run, &error) ||
      !RCContactStoreFinishRun(store, run, 1, NULL, &error) ||
      !RCContactStoreGetStatistics(store, &statistics, &error) ||
      statistics.missingCount != 1) {
    RCErrorSet(&error, 1, "completed inventory did not mark absent contact");
    goto failed;
  }
  if (!RCContactStoreBeginRun(store, &run, &error) ||
      !RCContactStoreMarkSeen(store, collectionIdentifier,
          "https://example.test/addressbook/contact-1.vcf", run, &error) ||
      !RCContactStoreFinishCollection(store, collectionIdentifier, run, &error) ||
      !RCContactStoreFinishRun(store, run, 1, NULL, &error) ||
      !RCContactStoreGetStatistics(store, &statistics, &error) ||
      statistics.availableCount != 1 || statistics.missingCount != 0) {
    RCErrorSet(&error, 1, "seen contact was not restored to available state");
    goto failed;
  }
  RCContactStoreClose(store);
  store = NULL;
  if (RCScalar(path, "SELECT COUNT(*) FROM contacts") != 1 ||
      RCScalar(path, "SELECT COUNT(*) FROM contact_properties") !=
          (int)document.propertyCount ||
      RCScalar(path, "SELECT COUNT(*) FROM contact_value_parts") != 12) {
    RCErrorSet(&error, 1, "relational vCard rows do not match parsed document");
    goto failed;
  }
  printf("Shared vCard and contact-store tests passed.\n");
  status = 0;
  goto finished;

failed_parse:
  RCVCardDocumentInit(&document);
failed:
  RCFail("shared test", &error);
finished:
  RCContactStoreClose(store);
  RCVCardDocumentClear(&document);
  unlink(path);
  return status;
}
