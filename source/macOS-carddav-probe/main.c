#include "RCCardDAVMirror.h"

#include <AltivecCore/curl/curl.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void RCPrintUsage(const char *program)
{
  fprintf(stderr,
      "Usage: %s --username address --database path --ca cacert.pem\n"
      "       [--url https://contacts.icloud.com]\n", program);
}

static void RCPrintProgress(const char *message, void *context)
{
  (void)context;
  fprintf(stderr, "%s...\n", message);
}

int main(int argc, char **argv)
{
  const char *username = NULL;
  const char *databasePath = NULL;
  const char *certificatePath = NULL;
  const char *serviceURL = "https://contacts.icloud.com";
  char *password;
  RCContactStore *store = NULL;
  RCCardDAVMirrorConfig config;
  RCCardDAVMirrorResult result;
  RCContactStoreStatistics statistics;
  RCError error;
  int index;
  int status = 1;
  int curlInitialized = 0;

  for (index = 1; index < argc; index++) {
    if (strcmp(argv[index], "--username") == 0 && index + 1 < argc) {
      username = argv[++index];
    } else if (strcmp(argv[index], "--database") == 0 && index + 1 < argc) {
      databasePath = argv[++index];
    } else if (strcmp(argv[index], "--ca") == 0 && index + 1 < argc) {
      certificatePath = argv[++index];
    } else if (strcmp(argv[index], "--url") == 0 && index + 1 < argc) {
      serviceURL = argv[++index];
    } else {
      RCPrintUsage(argv[0]);
      return 2;
    }
  }
  if (username == NULL || databasePath == NULL || certificatePath == NULL) {
    RCPrintUsage(argv[0]);
    return 2;
  }
  password = getpass("App-specific password: ");
  if (password == NULL || password[0] == '\0') {
    fprintf(stderr, "A password is required.\n");
    return 2;
  }
  RCErrorClear(&error);
  if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
    fprintf(stderr, "Could not initialize libcurl.\n");
    goto finished;
  }
  curlInitialized = 1;
  store = RCContactStoreOpen(databasePath, &error);
  if (store == NULL) goto failed;

  memset(&config, 0, sizeof(config));
  config.serviceURL = serviceURL;
  config.username = username;
  config.password = password;
  config.certificatePath = certificatePath;
  config.allowedHostSuffix = ".icloud.com";
  config.progress = RCPrintProgress;
  if (!RCCardDAVMirrorFetch(&config, store, &result, &error) ||
      !RCContactStoreGetStatistics(store, &statistics, &error)) goto failed;

  printf("Read-only CardDAV fetch complete.\n");
  printf("Collections: %ld\n", result.collectionCount);
  printf("Remote resources: %ld\n", result.listedResourceCount);
  printf("Downloaded: %ld\n", result.downloadedResourceCount);
  printf("Unchanged: %ld\n", result.unchangedResourceCount);
  printf("Database contacts: %ld available, %ld remotely absent\n",
         statistics.availableCount, statistics.missingCount);
  status = 0;
  goto finished;

failed:
  fprintf(stderr, "CardDAV fetch failed: %s\n",
          error.message[0] != '\0' ? error.message : "unknown error");
finished:
  RCContactStoreClose(store);
  if (curlInitialized) curl_global_cleanup();
  if (password != NULL) memset(password, 0, strlen(password));
  return status;
}
