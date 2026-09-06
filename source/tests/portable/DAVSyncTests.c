#include "RCCardDAVMirror.h"
#include "RCCalDAVMirror.h"
#include "RCDAVSyncState.h"
#include <libxml/parser.h>
#include <libxml/uri.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

static RCError error;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "Sync test line %d: %s (%s)\n", __LINE__, #x, error.message); exit(1); } } while (0)
#define ROOT "<d:multistatus xmlns:d='DAV:' xmlns:c='urn:ietf:params:xml:ns:caldav' xmlns:a='urn:ietf:params:xml:ns:carddav'>"
#define END "</d:multistatus>"
#define A "<d:response><d:href>a</d:href><d:propstat><d:prop><d:getetag>one</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
#define B "<d:response><d:href>b</d:href><d:propstat><d:prop><d:getetag>one</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
#define C "<d:response><d:href>c</d:href><d:propstat><d:prop><d:getetag>one</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
#define A2 "<d:response><d:href>a</d:href><d:propstat><d:prop><d:getetag>two</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
#define A3 "<d:response><d:href>a</d:href><d:propstat><d:prop><d:getetag>three</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
#define SELF(href) "<d:response><d:href>" href "</d:href><d:propstat><d:prop><d:getetag>collection-etag</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
#define DELETE_A "<d:response><d:href>a</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
#define DELETE_B "<d:response><d:href>b</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
#define EXPIRED "<d:error xmlns:d='DAV:'><d:valid-sync-token/></d:error>"
static const char *book = "https://example.test/home/book/";
static const char *t1 = "urn:sync:1?a=1&b=2";
static const char cardA[] = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:a\r\nN:A;Test;;;\r\nFN:Test A\r\nEND:VCARD\r\n";
static const char cardB[] = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:b\r\nN:B;Test;;;\r\nFN:Test B\r\nEND:VCARD\r\n";
static const char cardC[] = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:c\r\nN:C;Test;;;\r\nFN:Test C\r\nEND:VCARD\r\n";
static const char event[] = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART:20300601T120000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";

typedef struct { const char *method; char *body, *token, *etag; int status, sync; } Step;
static Step steps[80];
static int used, queued, getCount;
static void add(const char *method, int status, const char *body)
{
  Step *s;
  CHECK(queued < 80);
  s = &steps[queued++]; memset(s, 0, sizeof(*s));
  s->method = method; s->status = status; s->body = strdup(body); CHECK(s->body);
}
static void reset(void)
{
  int i;
  CHECK(used == queued);
  for (i = 0; i < queued; i++) { free(steps[i].body); free(steps[i].token); free(steps[i].etag); }
  used = queued = 0; RCErrorClear(&error);
}
static void get(const char *body, const char *etag)
{
  add("GET", 200, body); steps[queued - 1].etag = strdup(etag);
}
static void syncResponse(const char *input, int status, const char *body)
{
  add("REPORT", status, body); steps[queued - 1].sync = 1;
  steps[queued - 1].token = strdup(input ? input : "");
}
static void syncPage(const char *input, const char *output, const char *rows, int more)
{
  char xml[8192];
  xmlChar *escaped = xmlEncodeSpecialChars(NULL, (const xmlChar *)output);
  CHECK(escaped);
  snprintf(xml, sizeof(xml), ROOT "%s%s<d:sync-token>%s</d:sync-token>" END, rows,
      more ? "<d:response><d:href>/home/book/</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status>"
             "<d:error><d:number-of-matches-within-limits/></d:error></d:response>" : "",
      (const char *)escaped);
  xmlFree(escaped); syncResponse(input, 207, xml);
}
static void inventory(const char *rows, int calendar)
{
  char xml[8192]; snprintf(xml, sizeof(xml), ROOT "%s" END, rows);
  add(calendar ? "REPORT" : "PROPFIND", 207, xml);
}
static void discovery(int calendar, const char *token, int empty)
{
  char xml[4096];
  xmlChar *escaped = xmlEncodeSpecialChars(NULL, (const xmlChar *)(token ? token : ""));
  CHECK(escaped);
  add("PROPFIND", 207, ROOT "<d:response><d:propstat><d:prop><d:current-user-principal>"
      "<d:href>/principal/</d:href></d:current-user-principal></d:prop><d:status>HTTP/1.1 200 OK</d:status>"
      "</d:propstat></d:response>" END);
  snprintf(xml, sizeof(xml), ROOT "<d:response><d:propstat><d:prop><%s><d:href>/home/</d:href></%s>"
      "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>" END,
      calendar ? "c:calendar-home-set" : "a:addressbook-home-set",
      calendar ? "c:calendar-home-set" : "a:addressbook-home-set");
  add("PROPFIND", 207, xml);
  snprintf(xml, sizeof(xml), ROOT "<d:response><d:href>/home/book/</d:href><d:propstat><d:prop>"
      "<d:resourcetype><d:collection/><%s/></d:resourcetype>%s%s%s"
      "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>" END,
      calendar ? "c:calendar" : "a:addressbook", token ? "<d:sync-token>" : "",
      (const char *)escaped, token ? "</d:sync-token>" : "");
  add("PROPFIND", 207, empty ? ROOT END : xml); xmlFree(escaped);
}
RCHTTPClient *RCHTTPClientCreate(const RCHTTPClientConfig *c, RCError *e)
{ (void)c; (void)e; return malloc(1); }
void RCHTTPClientDestroy(RCHTTPClient *c) { free(c); }
void RCHTTPResponseInit(RCHTTPResponse *r) { memset(r, 0, sizeof(*r)); }
void RCHTTPResponseClear(RCHTTPResponse *r)
{ free(r->body); free(r->etag); free(r->effectiveURL); memset(r, 0, sizeof(*r)); }
int RCURLResolve(const char *base, const char *href, char **out, RCError *e)
{
  xmlChar *v = xmlBuildURI((const xmlChar *)href, (const xmlChar *)base);
  (void)e; *out = v ? strdup((const char *)v) : NULL; xmlFree(v); return *out != NULL;
}
int RCHTTPClientRequest(RCHTTPClient *c, const char *method, const char *url,
    const char *depth, const char *type, const void *body, size_t length, RCHTTPResponse *r, RCError *e)
{
  Step *s;
  (void)c; (void)type; (void)e;
  CHECK(used < queued); s = &steps[used++]; CHECK(!strcmp(method, s->method));
  if (s->sync) {
    xmlDocPtr doc = xmlReadMemory(body, (int)length, NULL, NULL, XML_PARSE_NONET);
    xmlXPathContextPtr context;
    xmlXPathObjectPtr token, shape;
    CHECK(doc && depth && !strcmp(depth, "0") && !strcmp(url, book));
    context = xmlXPathNewContext(doc); CHECK(context);
    xmlXPathRegisterNs(context, (xmlChar *)"d", (xmlChar *)"DAV:");
    token = xmlXPathEvalExpression((xmlChar *)"string(/d:sync-collection/d:sync-token)", context);
    shape = xmlXPathEvalExpression((xmlChar *)"count(/d:sync-collection/d:sync-token)=1 and "
        "string(/d:sync-collection/d:sync-level)='1' and count(/d:sync-collection/d:prop/d:getetag)=1", context);
    CHECK(token && !strcmp((char *)token->stringval, s->token) && shape && shape->boolval);
    xmlXPathFreeObject(token); xmlXPathFreeObject(shape); xmlXPathFreeContext(context); xmlFreeDoc(doc);
  } else if (!strcmp(method, "REPORT")) {
    CHECK(strstr(body, "calendar-query") && depth && !strcmp(depth, "1"));
  }
  if (!strcmp(method, "GET")) {
    CHECK(strcmp(url, book) && strcmp(url, "https://example.test/home/book"));
    getCount++;
  }
  RCHTTPResponseClear(r); r->statusCode = s->status; r->effectiveURL = strdup(url);
  r->body = (unsigned char *)strdup(s->body); r->bodyLength = strlen(s->body);
  r->etag = s->etag ? strdup(s->etag) : NULL;
  return 1;
}
static long long scalar(sqlite3 *db, const char *sql)
{
  sqlite3_stmt *q = NULL; long long n;
  CHECK(sqlite3_prepare_v2(db, sql, -1, &q, NULL) == SQLITE_OK && sqlite3_step(q) == SQLITE_ROW);
  n = sqlite3_column_int64(q, 0); sqlite3_finalize(q); return n;
}
static int tokenIs(sqlite3 *db, const char *account, const char *token)
{
  sqlite3_stmt *q = NULL; int result = 0;
  CHECK(sqlite3_prepare_v2(db, "SELECT token FROM dav_sync_state s JOIN accounts a ON a.id=s.account_id "
      "WHERE a.username=?", -1, &q, NULL) == SQLITE_OK);
  sqlite3_bind_text(q, 1, account, -1, SQLITE_TRANSIENT);
  if (sqlite3_step(q) == SQLITE_ROW) {
    const char *v = (const char *)sqlite3_column_text(q, 0);
    result = token ? v && !strcmp(v, token) : v == NULL;
  }
  sqlite3_finalize(q); return result;
}
static int callback(const RCDAVResource *rows, size_t count, void *context, RCError *e)
{
  int *counts = context; size_t i; (void)e;
  for (i = 0; i < count; i++) counts[rows[i].etag ? 0 : 1]++;
  return 1;
}
static void protocolTests(void)
{
  RCHTTPClientConfig config; RCHTTPClient *client; char *token = NULL;
  int counts[2] = {0, 0}; size_t i;
  const char *bad[] = {
    ROOT END, ROOT "<d:sync-token/>" END,
    ROOT A A "<d:sync-token>urn:new</d:sync-token>" END,
    ROOT "<d:response><d:href>a</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response><d:sync-token>urn:new</d:sync-token>" END,
    ROOT "<d:response><d:href>a</d:href><d:propstat><d:prop><d:getetag/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:sync-token>urn:new</d:sync-token>" END,
    ROOT "<d:sync-token>urn:x</d:sync-token><d:sync-token>urn:y</d:sync-token>" END,
    "<!DOCTYPE multistatus [<!ENTITY x 'bad'>]>" ROOT "<d:sync-token>urn:x</d:sync-token>" END,
    ROOT "<d:response><d:href>/home/book</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response><d:sync-token>urn:new</d:sync-token>" END,
    ROOT "<d:response><d:href>/home/book/</d:href><d:propstat><d:prop><d:getetag/></d:prop><d:status>HTTP/1.1 500 Error</d:status></d:propstat></d:response><d:sync-token>urn:new</d:sync-token>" END,
    ROOT "<d:response>"
  };
  memset(&config, 0, sizeof(config)); client = RCHTTPClientCreate(&config, &error); CHECK(client);
  syncPage(t1, "urn:page", A DELETE_B, 1); syncPage("urn:page", "urn:end", C, 0);
  CHECK(RCDAVSyncCollection(client, book, t1, callback, counts, &token, &error) == RCDAVSyncComplete);
  CHECK(counts[0] == 2 && counts[1] == 1 && !strcmp(token, "urn:end")); free(token); reset();
  for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    syncResponse(t1, 207, bad[i]);
    CHECK(RCDAVSyncCollection(client, book, t1, callback, counts, &token, &error) == RCDAVSyncFailed && !token);
    reset();
  }
  syncPage(t1, "urn:page", A, 1); syncPage("urn:page", t1, B, 1);
  CHECK(RCDAVSyncCollection(client, book, t1, callback, counts, &token, &error) == RCDAVSyncFailed && !token); reset();
  syncResponse(t1, 403, EXPIRED);
  CHECK(RCDAVSyncCollection(client, book, t1, callback, counts, &token, &error) == RCDAVSyncFallback); reset();
  syncResponse(t1, 403, "<d:error xmlns:d='DAV:'><d:need-privileges/></d:error>");
  CHECK(RCDAVSyncCollection(client, book, t1, callback, counts, &token, &error) == RCDAVSyncFailed); reset();
  syncResponse(t1, 405, "");
  CHECK(RCDAVSyncCollection(client, book, t1, callback, counts, &token, &error) == RCDAVSyncFallback); reset();
  syncPage(t1, t1, "", 0);
  CHECK(RCDAVSyncCollection(client, book, t1, callback, counts, &token, &error) == RCDAVSyncComplete); free(token); reset();
  /* The optional collection slash also applies to pagination markers. */
  counts[0] = counts[1] = 0;
  syncResponse(t1, 207, ROOT SELF("/home/book/") A
      "<d:response><d:href>/home/book</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status>"
      "<d:error><d:number-of-matches-within-limits/></d:error></d:response>"
      "<d:sync-token>urn:page</d:sync-token>" END);
  syncPage("urn:page", "urn:end", B, 0);
  CHECK(RCDAVSyncCollection(client, book, t1, callback, counts, &token, &error) == RCDAVSyncComplete);
  CHECK(counts[0] == 2 && counts[1] == 0 && !strcmp(token, "urn:end")); free(token); reset();
  RCHTTPClientDestroy(client);
}
static void contactTests(void)
{
  char path[] = "/tmp/rc-sync-contacts-XXXXXX";
  int fd = mkstemp(path), before, status;
  RCContactStore *store;
  RCDAVSyncState state;
  RCCardDAVMirrorConfig config = {"https://example.test/", "alice", "synthetic", "ca", NULL, NULL, NULL};
  RCCardDAVMirrorResult result;
  pid_t child;
  CHECK(fd >= 0); close(fd);
  store = RCContactStoreOpen(path, "alice", &error); CHECK(store);
  state = RCContactStoreDAVSyncState(store);
  discovery(0, t1, 0); syncPage(NULL, "urn:page", SELF("/home/book") A, 1); get(cardA, "one");
  syncPage("urn:page", t1, SELF("/home/book/") B, 0); get(cardB, "one");
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(result.listedResourceCount == 2 && result.downloadedResourceCount == 2);
  CHECK(tokenIs(state.db, "alice", t1) && scalar(state.db, "SELECT count(*) FROM contacts WHERE remote_missing=0") == 2);
  RCContactStoreClose(store); store = RCContactStoreOpen(path, "alice", &error); CHECK(store);
  state = RCContactStoreDAVSyncState(store);
  before = getCount;
  discovery(0, t1, 0); syncPage(t1, t1, SELF("/home/book"), 0);
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(getCount == before && scalar(state.db, "SELECT count(*) FROM contacts WHERE remote_missing=0") == 2);
  discovery(0, "urn:2", 0); syncPage(t1, "urn:2", A2 DELETE_B C, 0); get(cardA, "two"); get(cardC, "one");
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(tokenIs(state.db, "alice", "urn:2"));
  CHECK(scalar(state.db, "SELECT count(*) FROM contacts WHERE remote_missing=0") == 2);
  CHECK(scalar(state.db, "SELECT remote_missing FROM contacts WHERE uid='b'") == 1);
  /* Successful early page/GET followed by a failing page must roll back both. */
  discovery(0, "urn:3", 0); syncPage("urn:2", "urn:partial", A3, 1); get(cardA, "three");
  syncResponse("urn:partial", 503, "unavailable");
  CHECK(!RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(tokenIs(state.db, "alice", "urn:2") && scalar(state.db, "SELECT count(*) FROM contacts WHERE etag='three'") == 0);
  discovery(0, "urn:3", 0); syncPage("urn:2", "urn:3", A3, 0); get(cardA, "three");
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  /* Expiry on a continuation rolls back pages before an initial resync. */
  discovery(0, "urn:4", 0); syncPage("urn:3", "urn:partial", B, 1);
  syncResponse("urn:partial", 403, EXPIRED); syncPage(NULL, "urn:4", A3 C, 0);
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(tokenIs(state.db, "alice", "urn:4") && scalar(state.db, "SELECT remote_missing FROM contacts WHERE uid='b'") == 1);
  /* Expired token plus an unsupported initial report falls back to PROPFIND. */
  discovery(0, "urn:5", 0); syncResponse("urn:4", 403, EXPIRED); syncResponse(NULL, 405, ""); inventory(A3 C, 0);
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(tokenIs(state.db, "alice", NULL));
  discovery(0, "urn:5", 0); syncPage(NULL, "urn:5", A3 C, 0);
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(tokenIs(state.db, "alice", "urn:5"));
  /* Failed GET cannot advance an otherwise successful delta token. */
  discovery(0, "urn:6", 0); syncPage("urn:5", "urn:6", A2, 0); add("GET", 503, "unavailable");
  CHECK(!RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(tokenIs(state.db, "alice", "urn:5"));
  /* Process termination after recording data AND a token but before commit. */
  RCContactStoreClose(store); store = NULL;
  child = fork(); CHECK(child >= 0);
  if (!child) {
    long long run, collection; int invalid;
    RCContactStore *writer = RCContactStoreOpen(path, "alice", &error);
    RCDAVSyncState w = RCContactStoreDAVSyncState(writer);
    if (!writer || !RCContactStoreBeginRun(writer, &run, &error) ||
        !RCContactStoreGetCollection(writer, book, NULL, &collection, &error) ||
        !RCContactStoreSaveResource(writer, collection, run, "https://example.test/home/book/a", "crash",
            (const unsigned char *)cardA, strlen(cardA), &invalid, &error) ||
        !RCDAVSyncStateSave(&w, book, "urn:crash", "", run, &error)) _exit(2);
    _exit(0);
  }
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  store = RCContactStoreOpen(path, "alice", &error); CHECK(store); state = RCContactStoreDAVSyncState(store);
  CHECK(tokenIs(state.db, "alice", "urn:5") && scalar(state.db, "SELECT count(*) FROM contacts WHERE etag='crash'") == 0);
  /* Identical collection URLs across accounts cannot share tokens. */
  RCContactStoreClose(store); store = RCContactStoreOpen(path, "bob", &error); CHECK(store);
  state = RCContactStoreDAVSyncState(store); config.username = "bob";
  discovery(0, "urn:bob", 0); syncPage(NULL, "urn:bob", A, 0); get(cardA, "one");
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(tokenIs(state.db, "bob", "urn:bob") && tokenIs(state.db, "alice", "urn:5"));
  RCContactStoreClose(store); store = RCContactStoreOpen(path, "alice", &error); CHECK(store);
  state = RCContactStoreDAVSyncState(store); config.username = "alice";
  discovery(0, NULL, 1);
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(!tokenIs(state.db, "alice", "urn:5") && tokenIs(state.db, "bob", "urn:bob"));
  discovery(0, "urn:5", 0); syncPage(NULL, "urn:5", A3 C, 0);
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(tokenIs(state.db, "alice", "urn:5"));
  /* Server without sync support still uses its full inventory. */
  discovery(0, NULL, 0); inventory(A3 C, 0);
  CHECK(RCCardDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(tokenIs(state.db, "alice", NULL));
  RCContactStoreClose(store); unlink(path);
}
static void calendarTests(void)
{
  char path[] = "/tmp/rc-sync-calendar-XXXXXX";
  int fd = mkstemp(path), before;
  RCCalendarStore *store;
  RCCardDAVMirrorConfig config = {"https://example.test/", "alice", "synthetic", "ca", NULL, NULL, NULL};
  RCCardDAVMirrorResult result;
  const char *wide = "20240906T000000Z", *narrow = "20250906T000000Z";
  CHECK(fd >= 0); close(fd);
  store = RCCalendarStoreOpen(path, "alice", &error); CHECK(store);
  /* Baseline token is captured before inventory/GET, never after them. */
  discovery(1, t1, 0); inventory(A, 1); get(event, "two");
  CHECK(RCCalDAVMirrorFetchSince(&config, store, wide, &result, &error)); reset();
  CHECK(tokenIs(store->db, "alice", t1));
  before = getCount;
  discovery(1, "urn:2", 0); syncPage(t1, "urn:2", A2, 0); inventory(A2, 1);
  CHECK(RCCalDAVMirrorFetchSince(&config, store, wide, &result, &error)); reset();
  CHECK(getCount == before && tokenIs(store->db, "alice", "urn:2"));
  RCCalendarStoreClose(store); store = RCCalendarStoreOpen(path, "alice", &error); CHECK(store);
  discovery(1, "urn:2", 0); syncPage("urn:2", "urn:2", "", 0);
  CHECK(RCCalDAVMirrorFetchSince(&config, store, wide, &result, &error)); reset();
  CHECK(result.unchangedResourceCount == 1 && scalar(store->db, "SELECT count(*) FROM available_events") == 1);
  /* Same token, new cutoff: must query again to age records out. */
  discovery(1, "urn:2", 0); inventory("", 1);
  CHECK(RCCalDAVMirrorFetchSince(&config, store, narrow, &result, &error)); reset();
  CHECK(scalar(store->db, "SELECT count(*) FROM available_events") == 0);
  CHECK(scalar(store->db, "SELECT scope_excluded FROM calendar_resources") == 1);
  CHECK(scalar(store->db, "SELECT remote_missing FROM calendar_resources") == 0);
  discovery(1, "urn:2", 0); inventory(A2, 1);
  CHECK(RCCalDAVMirrorFetchSince(&config, store, wide, &result, &error)); reset();
  CHECK(scalar(store->db, "SELECT count(*) FROM available_events") == 1);
  /* A changed out-of-window resource triggers filtering, but is not downloaded. */
  discovery(1, "urn:3", 0); syncPage("urn:2", "urn:page", B, 1); syncPage("urn:page", "urn:3", C, 0); inventory(A2, 1);
  CHECK(RCCalDAVMirrorFetchSince(&config, store, wide, &result, &error)); reset();
  CHECK(getCount == before && tokenIs(store->db, "alice", "urn:3"));
  /* Failed inventory after a successful sync response retains data and token. */
  discovery(1, "urn:4", 0); syncPage("urn:3", "urn:4", DELETE_A, 0); add("REPORT", 503, "unavailable");
  CHECK(!RCCalDAVMirrorFetchSince(&config, store, wide, &result, &error)); reset();
  CHECK(tokenIs(store->db, "alice", "urn:3") && scalar(store->db, "SELECT count(*) FROM available_events") == 1);
  discovery(1, "urn:4", 0); syncResponse("urn:3", 403, EXPIRED); inventory(A2, 1);
  CHECK(RCCalDAVMirrorFetchSince(&config, store, wide, &result, &error)); reset();
  CHECK(tokenIs(store->db, "alice", "urn:4"));
  discovery(1, "urn:5", 0); syncPage("urn:4", "urn:5", DELETE_A, 0); inventory("", 1);
  CHECK(RCCalDAVMirrorFetchSince(&config, store, wide, &result, &error)); reset();
  CHECK(scalar(store->db, "SELECT count(*) FROM available_events") == 0);
  /* Failed scope expansion does not overwrite the persisted cutoff. */
  discovery(1, "urn:5", 0); add("PROPFIND", 503, "unavailable");
  CHECK(!RCCalDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(scalar(store->db, "SELECT count(*) FROM dav_sync_state WHERE scope='20240906T000000Z'") == 1);
  discovery(1, "urn:5", 0); inventory(A2, 0);
  CHECK(RCCalDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(scalar(store->db, "SELECT count(*) FROM available_events") == 1);
  /* Removed/recreated collections must not reuse their old cursors. */
  discovery(1, NULL, 1); CHECK(RCCalDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(scalar(store->db, "SELECT count(*) FROM dav_sync_state") == 0);
  discovery(1, "urn:5", 0); inventory(A2, 0);
  CHECK(RCCalDAVMirrorFetch(&config, store, &result, &error)); reset();
  CHECK(scalar(store->db, "SELECT count(*) FROM available_events") == 1);
  RCCalendarStoreClose(store); unlink(path);
}
int main(void)
{
  protocolTests(); contactTests(); calendarTests();
  puts("DAV sync tokens: paging, expiry, fallback, crash rollback, account isolation and calendar windows passed.");
  return 0;
}
