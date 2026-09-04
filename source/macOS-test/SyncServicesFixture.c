#include "RCContactStore.h"
#include "RCVCard.h"

#include <stdio.h>
#include <string.h>

static const unsigned char kRCInitialAlpha[] =
    "BEGIN:VCARD\r\n"
    "VERSION:3.0\r\n"
    "UID:retrocloud-syncservices-test-alpha\r\n"
    "N:Fixture;RCSSTestAlpha;;;\r\n"
    "FN:RCSSTestAlpha Fixture\r\n"
    "ORG:Retro Cloud Test;Initial\r\n"
    "TITLE:Initial Tester\r\n"
    "BDAY:2001-02-03\r\n"
    "TEL;TYPE=CELL,PREF:+1-555-0101\r\n"
    "EMAIL;TYPE=WORK,PREF:initial-alpha@retrocloudsync.invalid\r\n"
    "ADR;TYPE=WORK:;;1 Static Way;Testville;CA;90001;USA\r\n"
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

static const unsigned char kRCInitialBeta[] =
    "BEGIN:VCARD\r\n"
    "VERSION:3.0\r\n"
    "UID:retrocloud-syncservices-test-beta\r\n"
    "N:Fixture;RCSSTestBeta;;;\r\n"
    "FN:RCSSTestBeta Fixture\r\n"
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
  int success = 0;

  if (argc != 3) {
    fprintf(stderr, "usage: %s initial|updated|empty DATABASE\n", argv[0]);
    return 2;
  }
  isInitial = strcmp(argv[1], "initial") == 0;
  isUpdated = strcmp(argv[1], "updated") == 0;
  isEmpty = strcmp(argv[1], "empty") == 0;
  if (!isInitial && !isUpdated && !isEmpty) {
    fprintf(stderr, "Unknown fixture phase: %s\n", argv[1]);
    return 2;
  }

  RCErrorClear(&error);
  store = RCContactStoreOpen(argv[2], &error);
  if (store == NULL ||
      !RCContactStoreBeginRun(store, &runIdentifier, &error) ||
      !RCContactStoreGetCollection(store,
          "https://syncservices-test.invalid/addressbook/", "Test Contacts",
          &collectionIdentifier, &error)) goto finished;

  if (isInitial) {
    if (!RCSaveVCard(store, collectionIdentifier, runIdentifier,
            "https://syncservices-test.invalid/addressbook/alpha.vcf",
            "\"initial-alpha\"", kRCInitialAlpha,
            sizeof(kRCInitialAlpha) - 1, &error) ||
        !RCSaveVCard(store, collectionIdentifier, runIdentifier,
            "https://syncservices-test.invalid/addressbook/beta.vcf",
            "\"initial-beta\"", kRCInitialBeta,
            sizeof(kRCInitialBeta) - 1, &error)) goto finished;
  } else if (isUpdated) {
    if (!RCSaveVCard(store, collectionIdentifier, runIdentifier,
            "https://syncservices-test.invalid/addressbook/alpha.vcf",
            "\"updated-alpha\"", kRCUpdatedAlpha,
            sizeof(kRCUpdatedAlpha) - 1, &error)) goto finished;
  }

  if (!RCContactStoreFinishCollection(store, collectionIdentifier,
          runIdentifier, &error) ||
      !RCContactStoreFinishRun(store, runIdentifier, 1, NULL, &error)) {
    goto finished;
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
