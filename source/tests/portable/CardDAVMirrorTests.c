#include "RCCardDAVMirror.h"
#include "RCSQLite.h"
#include <libxml/uri.h>
#include <libxml/xmlmemory.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

/* Real discovery, mirror and store with deterministic HTTP responses. Accounts
   intentionally share URLs and UIDs: neither is a substitute for ownership. */
enum { Initial, Invalid, Repaired, OmitCollection, EmptyHome, HomeDenied,
       InventoryDenied, InterruptedDownload, TruncatedHome };
static int mode, requests, getCount;
struct RCHTTPClient { char *username; };
RCHTTPClient *RCHTTPClientCreate(const RCHTTPClientConfig *c, RCError *e)
{
  RCHTTPClient *client = calloc(1, sizeof(*client));
  (void)e;
  if (client) client->username = strdup(c->username);
  return client;
}
void RCHTTPClientDestroy(RCHTTPClient *c)
{
  if (c) { free(c->username); free(c); }
}
void RCHTTPResponseInit(RCHTTPResponse *r) { memset(r, 0, sizeof(*r)); }
void RCHTTPResponseClear(RCHTTPResponse *r)
{
  free(r->body); free(r->etag); free(r->effectiveURL);
  memset(r, 0, sizeof(*r));
}
int RCURLResolve(const char *base, const char *href, char **out, RCError *e)
{
  xmlChar *url = xmlBuildURI((const xmlChar *)href, (const xmlChar *)base);
  (void)e;
  *out = url ? strdup((const char *)url) : NULL;
  xmlFree(url);
  return *out != NULL;
}
#define XML_BEGIN "<d:multistatus xmlns:d='DAV:' xmlns:c='urn:ietf:params:xml:ns:carddav'>"
#define XML_END "</d:multistatus>"
#define COLLECTION(name) "<d:response><d:href>/home/" name "/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:addressbook/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
static void resource(char *xml, const char *name, const char *etag)
{
  char row[512];
  snprintf(row, sizeof(row), "<d:response><d:href>%s.vcf</d:href><d:propstat><d:prop><d:getetag>%s</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>", name, etag);
  strcat(xml, row);
}
int RCHTTPClientRequest(RCHTTPClient *c, const char *method, const char *url,
                        const char *depth, const char *type, const void *body,
                        size_t length, RCHTTPResponse *r, RCError *e)
{
  char xml[4096];
  const char *request = body;
  int changed = mode == Invalid || mode == Repaired || mode == InterruptedDownload;
  (void)depth; (void)type; (void)length; (void)e;
  requests++;
  RCHTTPResponseClear(r);
  r->effectiveURL = strdup(url);
  r->statusCode = 207;
  if (!strcmp(method, "GET")) {
    const char *name = strrchr(url, '/') + 1;
    getCount++;
    r->statusCode = mode == InterruptedDownload && !strcmp(name, "b.vcf") ? 503 : 200;
    r->etag = strdup(mode == Repaired ? "fixed" : changed ? "changed" : "initial");
    if (mode == Invalid && !strcmp(name, "new.vcf"))
      xml[0] = '\0';
    else if (mode == Invalid && !strcmp(name, "a.vcf"))
      strcpy(xml, "invalid downloaded vCard\r\n");
    else
      snprintf(xml, sizeof(xml), "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:%s\r\nN:Fixture;%s;;;\r\nFN:%s %s %s\r\nTEL:123\r\nEND:VCARD\r\n", name, c->username, c->username, name, changed ? "changed" : "initial");
  } else if (strstr(request, "current-user-principal")) {
    strcpy(xml, XML_BEGIN "<d:response><d:propstat><d:prop><d:current-user-principal><d:href>/principal/</d:href></d:current-user-principal></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>" XML_END);
  } else if (strstr(request, "addressbook-home-set")) {
    strcpy(xml, XML_BEGIN "<d:response><d:propstat><d:prop><c:addressbook-home-set><d:href>/home/</d:href></c:addressbook-home-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>" XML_END);
  } else if (!strcmp(url, "https://example.test/home/")) {
    strcpy(xml, XML_BEGIN);
    if (mode == HomeDenied)
      strcat(xml, "<d:response><d:href>/home/primary/</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response>");
    else if (mode != EmptyHome) {
      strcat(xml, COLLECTION("primary"));
      if (mode != OmitCollection && mode != InterruptedDownload)
        strcat(xml, COLLECTION("secondary"));
    }
    if (mode != TruncatedHome) strcat(xml, XML_END);
  } else {
    strcpy(xml, XML_BEGIN);
    if (mode == InventoryDenied)
      strcat(xml, "<d:response><d:href>a.vcf</d:href><d:propstat><d:prop><d:getetag/></d:prop><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response>");
    else if (strstr(url, "/primary/")) {
      resource(xml, "a", mode == Repaired ? "fixed" : changed ? "changed" : "initial");
      resource(xml, "b", mode == Repaired ? "fixed" : changed ? "changed" : "initial");
      if (mode == Invalid || mode == Repaired) resource(xml, "new", mode == Repaired ? "fixed" : "changed");
    } else resource(xml, "c", "initial");
    strcat(xml, XML_END);
  }
  r->bodyLength = strlen(xml);
  r->body = r->bodyLength ? (unsigned char *)strdup(xml) : NULL;
  return 1;
}

static int scalar(const char *path, const char *sql)
{
  sqlite3 *db = NULL;
  sqlite3_stmt *q = NULL;
  int result = -1;
  if (sqlite3_open(path, &db) == SQLITE_OK &&
      sqlite3_prepare_v2(db, sql, -1, &q, NULL) == SQLITE_OK &&
      sqlite3_step(q) == SQLITE_ROW) result = sqlite3_column_int(q, 0);
  sqlite3_finalize(q); sqlite3_close(db);
  return result;
}
typedef struct { int count; char firstID[33]; char bodies[8192]; } Export;
static int collect(long long id, const char *syncID, const unsigned char *body,
                    size_t length, void *context, RCError *error)
{
  Export *out = context;
  (void)id; (void)error;
  if (!out->count) snprintf(out->firstID, sizeof(out->firstID), "%s", syncID);
  if (strlen(out->bodies) + length >= sizeof(out->bodies)) return 0;
  strncat(out->bodies, (const char *)body, length);
  out->count++;
  return 1;
}
static int exported(RCContactStore *s, Export *out, RCError *e)
{
  memset(out, 0, sizeof(*out));
  return RCContactStoreForEachAvailableContact(s, collect, out, e);
}
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"Contact regression line %d: %s (%s)\n",__LINE__,#x,e.message); goto done; } } while (0)
int main(void)
{
  char path[] = "/tmp/rc-contacts-dav-XXXXXX";
  char accountID[33], contactID[33], childID[33];
  int fd = mkstemp(path), ok = 0, i, parseFailed, childStatus;
  long long generation, published, savedGeneration, run, collection;
  RCContactStore *s = NULL;
  RCCardDAVMirrorConfig config = {"https://example.test/", "alice", "synthetic", "mock-ca", NULL, NULL, NULL};
  RCCardDAVMirrorResult result;
  RCContactStoreStatistics statistics;
  Export out;
  RCError e;
  pid_t child;
  RCErrorClear(&e);
  if (fd < 0) return 1;
  close(fd);
  s = RCContactStoreOpen(path, "alice", &e);
  CHECK(s);
  strcpy(accountID, RCContactStoreSyncIdentifier(s));
  CHECK(RCContactStoreGetPublicationState(s, &generation, &published, &e) && generation == 0 && published == 0);
  CHECK(!RCContactStoreMarkPublished(s, 0, &e));
  CHECK(RCCardDAVMirrorFetch(&config, s, &result, &e));
  CHECK(exported(s, &out, &e) && out.count == 3 && strstr(out.bodies, "alice a.vcf initial"));
  strcpy(contactID, out.firstID);
  CHECK(RCContactStoreGetPublicationState(s, &generation, &published, &e) && generation > 0 && published == 0);
  CHECK(RCContactStoreMarkPublished(s, generation, &e));
  savedGeneration = generation;
  /* Failed home discovery, malformed XML, a mixed propstat, and a late GET
     failure must leave both the complete graph and generation intact. */
  for (i = HomeDenied; i <= TruncatedHome; i++) {
    mode = i;
    CHECK(!RCCardDAVMirrorFetch(&config, s, &result, &e));
    CHECK(exported(s, &out, &e) && out.count == 3 && strstr(out.bodies, "alice a.vcf initial"));
    CHECK(RCContactStoreGetPublicationState(s, &generation, &published, &e) && generation == savedGeneration && published == generation);
  }
  /* A malformed replacement preserves exact usable bytes/identities, while
     another contact updates and a malformed new contact stays unexported. */
  mode = Invalid;
  CHECK(RCCardDAVMirrorFetch(&config, s, &result, &e));
  CHECK(exported(s, &out, &e) && out.count == 3 && !strcmp(contactID, out.firstID));
  CHECK(strstr(out.bodies, "alice a.vcf initial") && strstr(out.bodies, "alice b.vcf changed"));
  CHECK(RCContactStoreGetStatistics(s, &statistics, &e) && statistics.availableCount == 4 && statistics.parseErrorCount == 2);
  CHECK(scalar(path, "SELECT count(*) FROM contacts WHERE CAST(raw_vcard AS TEXT)='invalid downloaded vCard'||char(13)||char(10) AND parse_error IS NOT NULL") == 1);
  CHECK(scalar(path, "SELECT count(*) FROM contacts WHERE length(raw_vcard)=0 AND parse_error IS NOT NULL AND usable_vcard IS NULL") == 1);
  getCount = 0;
  CHECK(RCCardDAVMirrorFetch(&config, s, &result, &e) && getCount == 0);
  CHECK(RCContactStoreGetPublicationState(s, &generation, &published, &e) && generation > published);
  savedGeneration = generation;
  RCContactStoreClose(s); s = NULL;
  /* Durable replay after a failed publication and an offline restart. */
  s = RCContactStoreOpen(path, "ALICE", &e);
  CHECK(s && !strcmp(accountID, RCContactStoreSyncIdentifier(s)));
  mode = HomeDenied;
  CHECK(!RCCardDAVMirrorFetch(&config, s, &result, &e));
  CHECK(exported(s, &out, &e) && out.count == 3 && !strcmp(contactID, out.firstID));
  CHECK(RCContactStoreGetPublicationState(s, &generation, &published, &e) && generation == savedGeneration && generation > published);
  CHECK(RCContactStoreMarkPublished(s, generation, &e));
  mode = Repaired;
  CHECK(RCCardDAVMirrorFetch(&config, s, &result, &e));
  CHECK(exported(s, &out, &e) && out.count == 4 && !strcmp(contactID, out.firstID));
  CHECK(RCContactStoreGetStatistics(s, &statistics, &e) && statistics.parseErrorCount == 0);
  CHECK(!RCContactStoreMarkPublished(s, savedGeneration, &e));
  CHECK(RCContactStoreGetCollection(s, "https://example.test/home/primary/", NULL, &collection, &e));
  /* Open another account using the exact same URLs and UIDs. Its fresh cache
     must not expose Alice, even before its first successful fetch. */
  RCContactStoreClose(s); s = RCContactStoreOpen(path, "bob", &e);
  CHECK(s && strcmp(accountID, RCContactStoreSyncIdentifier(s)));
  CHECK(exported(s, &out, &e) && out.count == 0);
  CHECK(RCContactStoreGetPublicationState(s, &generation, &published, &e) && generation == 0);
  requests = 0;
  CHECK(!RCCardDAVMirrorFetch(&config, s, &result, &e) && requests == 0);
  CHECK(RCContactStoreBeginRun(s, &run, &e));
  CHECK(!RCContactStoreMarkSeen(s, collection, "https://example.test/home/primary/a.vcf", run, &e));
  CHECK(RCContactStoreFinishRun(s, run, 0, "wrong account", &e));
  config.username = "bob"; mode = Initial;
  CHECK(RCCardDAVMirrorFetch(&config, s, &result, &e));
  CHECK(exported(s, &out, &e) && out.count == 3 && !strstr(out.bodies, "alice") && strcmp(contactID, out.firstID));
  strcpy(childID, out.firstID);
  mode = EmptyHome;
  CHECK(RCCardDAVMirrorFetch(&config, s, &result, &e));
  CHECK(exported(s, &out, &e) && out.count == 0);
  CHECK(RCContactStoreGetStatistics(s, &statistics, &e) && statistics.missingCount == 3);
  mode = Initial;
  CHECK(RCCardDAVMirrorFetch(&config, s, &result, &e));
  CHECK(exported(s, &out, &e) && out.count == 3 && !strcmp(childID, out.firstID));
  RCContactStoreClose(s); s = RCContactStoreOpen(path, "alice", &e);
  config.username = "alice";
  CHECK(s && exported(s, &out, &e) && out.count == 4);
  mode = OmitCollection;
  CHECK(RCCardDAVMirrorFetch(&config, s, &result, &e));
  CHECK(exported(s, &out, &e) && out.count == 2);
  CHECK(RCContactStoreGetStatistics(s, &statistics, &e) && statistics.missingCount == 2);
  CHECK(RCContactStoreGetPublicationState(s, &generation, &published, &e));
  savedGeneration = generation;
  RCContactStoreClose(s); s = NULL;
  /* Kill the writer with an open SQLite transaction: no new resource or
     pending deletion can survive into the next publication. */
  child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    RCContactStore *writer = RCContactStoreOpen(path, "alice", &e);
    if (!writer || !RCContactStoreBeginRun(writer, &run, &e) ||
        !RCContactStoreGetCollection(writer, "https://example.test/home/primary/", NULL, &collection, &e) ||
        !RCContactStoreSaveResource(writer, collection, run, "https://example.test/home/primary/partial.vcf", "partial", (const unsigned char *)"broken", 6, &parseFailed, &e) ||
        !RCContactStoreFinishCollection(writer, collection, run, &e)) _exit(2);
    _exit(0);
  }
  CHECK(waitpid(child, &childStatus, 0) == child && WIFEXITED(childStatus) && WEXITSTATUS(childStatus) == 0);
  s = RCContactStoreOpen(path, "alice", &e);
  CHECK(s && exported(s, &out, &e) && out.count == 2);
  CHECK(RCContactStoreGetPublicationState(s, &generation, &published, &e) && generation == savedGeneration);
  CHECK(scalar(path, "SELECT count(*) FROM contacts WHERE etag='partial'") == 0);
  CHECK(scalar(path, "SELECT count(*) FROM pragma_foreign_key_check") == 0);
  puts("Contact account isolation, collection retirement, malformed resources, rollback and publication recovery tests passed.");
  ok = 1;
done:
  RCContactStoreClose(s); unlink(path);
  return ok ? 0 : 1;
}
