#include "RCCalDAVMirror.h"
#include <libxml/uri.h>
#include <libxml/xmlmemory.h>
#include <libxml/parser.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int mode, getCount, historyFixtures, reportCount;
/* The synthetic server has explicit expected overlap boundaries, independent
   of the production code. The series began in 2010 and has a future override. */
#define EVENT(text) "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" text "END:VCALENDAR\r\n"
static const struct { const char *name, *lastEnd, *body; } history[] = {
  {"old", "20100602T000000Z", EVENT("BEGIN:VEVENT\r\nUID:old\r\nDTSTART;VALUE=DATE:20100601\r\nEND:VEVENT\r\n")},
  {"recent", "20250601T130000Z", EVENT("BEGIN:VEVENT\r\nUID:recent\r\nDTSTART:20250601T120000Z\r\nDTEND:20250601T130000Z\r\nEND:VEVENT\r\n")},
  {"series", NULL, EVENT("BEGIN:VEVENT\r\nUID:series\r\nDTSTART:20100601T120000Z\r\nRRULE:FREQ=YEARLY\r\nEND:VEVENT\r\n"
      "BEGIN:VEVENT\r\nUID:series\r\nRECURRENCE-ID:20300601T120000Z\r\nDTSTART:20300602T120000Z\r\nEND:VEVENT\r\n")},
  {"future", "20400601T130000Z", EVENT("BEGIN:VEVENT\r\nUID:future\r\nDTSTART:20400601T120000Z\r\nDTEND:20400601T130000Z\r\nEND:VEVENT\r\n")},
  {"span", "20240907T000000Z", EVENT("BEGIN:VEVENT\r\nUID:span\r\nDTSTART;VALUE=DATE:20240905\r\nDTEND;VALUE=DATE:20240907\r\nEND:VEVENT\r\n")}
};
static int historyResponse(const char *method, const char *url, const char *depth,
                            const void *body, size_t length, RCHTTPResponse *r, RCError *e)
{
  char xml[4096];
  size_t i;
  char *cutoff = NULL;
  if (!strcmp(method, "GET")) {
    for (i = 0; i < sizeof(history) / sizeof(history[0]); i++) {
      char suffix[64];
      snprintf(suffix, sizeof(suffix), "/%s.ics", history[i].name);
      if (!strstr(url, suffix)) continue;
      getCount++;
      r->statusCode = 200;
      r->etag = strdup("\"one\"");
      r->body = (unsigned char *)strdup(history[i].body);
      r->bodyLength = strlen(history[i].body);
      return 1;
    }
    return 0;
  }
  if (!strcmp(method, "REPORT")) {
    xmlDocPtr doc = xmlReadMemory(body, (int)length, NULL, NULL, XML_PARSE_NONET);
    xmlXPathContextPtr context = doc ? xmlXPathNewContext(doc) : NULL;
    xmlXPathObjectPtr shape = NULL, start = NULL;
    int valid = 0;
    if (context) {
      xmlXPathRegisterNs(context, (xmlChar *)"c", (xmlChar *)"urn:ietf:params:xml:ns:caldav");
      xmlXPathRegisterNs(context, (xmlChar *)"d", (xmlChar *)"DAV:");
      shape = xmlXPathEvalExpression((xmlChar *)
          "count(/c:calendar-query/d:prop/d:getetag)=1 and "
          "count(//c:time-range)=1 and count(//c:time-range/@end)=0 and "
          "count(//c:calendar-data)=0", context);
      start = xmlXPathEvalExpression((xmlChar *)
          "string(/c:calendar-query/c:filter/c:comp-filter[@name='VCALENDAR']/"
          "c:comp-filter[@name='VEVENT']/c:time-range/@start)", context);
      valid = shape && shape->boolval && start && start->stringval &&
          strlen((char *)start->stringval) == 16 && depth && !strcmp(depth, "1");
      if (valid) cutoff = strdup((char *)start->stringval);
    }
    xmlXPathFreeObject(shape); xmlXPathFreeObject(start);
    xmlXPathFreeContext(context); xmlFreeDoc(doc);
    if (!valid || !cutoff) { RCErrorSet(e, 1, "Invalid history REPORT"); return 0; }
    reportCount++;
  } else if (strcmp(method, "PROPFIND")) return 0;
  strcpy(xml, "<d:multistatus xmlns:d='DAV:'>");
  for (i = 0; i < sizeof(history) / sizeof(history[0]); i++) {
    char item[512];
    if (cutoff && history[i].lastEnd && strcmp(history[i].lastEnd, cutoff) <= 0) continue;
    snprintf(item, sizeof(item), "<d:response><d:href>%s.ics</d:href><d:propstat>"
        "<d:prop><d:getetag>&quot;one&quot;</d:getetag></d:prop>"
        "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>", history[i].name);
    strcat(xml, item);
  }
  strcat(xml, "</d:multistatus>");
  free(cutoff);
  r->body = (unsigned char *)strdup(xml);
  r->bodyLength = strlen(xml);
  return 1;
}
static const char data[] =
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:mock\r\nDTSTART:"
    "20300601T120000Z\r\nSUMMARY:Mock\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
RCHTTPClient *RCHTTPClientCreate(const RCHTTPClientConfig *c, RCError *e)
{
  (void)c;
  (void)e;
  return (RCHTTPClient *)malloc(1);
}
void RCHTTPClientDestroy(RCHTTPClient *c) { free(c); }
void RCHTTPResponseInit(RCHTTPResponse *r) { memset(r, 0, sizeof(*r)); }
void RCHTTPResponseClear(RCHTTPResponse *r)
{
  free(r->body);
  free(r->etag);
  free(r->effectiveURL);
  memset(r, 0, sizeof(*r));
}
int RCURLResolve(const char *base, const char *href, char **out, RCError *e)
{
  xmlChar *u = xmlBuildURI((const xmlChar *)href, (const xmlChar *)base);
  (void)e;
  *out = u ? strdup((const char *)u) : NULL;
  xmlFree(u);
  return *out != NULL;
}
int RCHTTPClientRequest(RCHTTPClient *c, const char *method, const char *url,
                        const char *depth, const char *type, const void *body,
                        size_t length, RCHTTPResponse *r, RCError *e)
{
  const char *xml = NULL;
  const char *request = (const char *)body;
  (void)c;
  (void)depth;
  (void)type;
  (void)length;
  (void)e;
  RCHTTPResponseClear(r);
  r->statusCode = 207;
  r->effectiveURL = strdup(url);
  if (historyFixtures && ((!strcmp(method, "GET")) ||
      (!strcmp(url, "https://example.test/home/cal/") && mode == 0)))
    return historyResponse(method, url, depth, body, length, r, e);
  if (!strcmp(method, "GET")) {
    getCount++;
    r->statusCode = mode == 3 ? 503 : 200;
    xml = data;
    r->etag = strdup("one");
  } else if (strstr(request, "current-user-principal"))
    xml = "<d:multistatus "
          "xmlns:d='DAV:'><d:response><d:propstat><d:prop><d:current-user-principal><d:"
          "href>/principal/</d:href></d:current-user-principal></d:prop><d:status>HTTP/"
          "1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>";
  else if (strstr(request, "calendar-home-set"))
    xml = "<d:multistatus xmlns:d='DAV:' "
          "xmlns:c='urn:ietf:params:xml:ns:caldav'><d:response><d:propstat><d:prop><c:"
          "calendar-home-set><d:href>/home/</d:href></c:calendar-home-set></"
          "d:prop><d:status>HTTP/1.1 200 "
          "OK</d:status></d:propstat></d:response></d:multistatus>";
  else if (!strcmp(url, "https://example.test/home/")) {
    if (mode == 5)
      xml = "<d:multistatus xmlns:d='DAV:'/>";
    else if (mode == 4)
      xml = "<d:multistatus "
            "xmlns:d='DAV:'><d:response><d:href>/home/cal/</d:href><d:status>HTTP/1.1 "
            "403 Forbidden</d:status></d:response></d:multistatus>";
    else
      xml = "<x:multistatus xmlns:x='DAV:' "
            "xmlns:c='urn:ietf:params:xml:ns:caldav'><x:response><x:href>cal/</"
            "x:href><x:propstat><x:prop><x:resourcetype><x:collection/><c:calendar/></"
            "x:resourcetype><x:displayname>Mock "
            "Calendar</x:displayname></x:prop><x:status>HTTP/1.1 200 "
            "OK</x:status></x:propstat><x:propstat><x:prop><c:calendar-description/></"
            "x:prop><x:status>HTTP/1.1 404 Not "
            "Found</x:status></x:propstat></x:response></x:multistatus>";
  } else {
    if (mode == 1)
      xml = "<d:multistatus xmlns:d='DAV:'/>";
    else if (mode == 2)
      xml = "<d:multistatus "
            "xmlns:d='DAV:'><d:response><d:href>item.ics</"
            "d:href><d:propstat><d:prop><d:getetag/></d:prop><d:status>HTTP/1.1 403 "
            "Forbidden</d:status></d:propstat></d:response></d:multistatus>";
    else if (mode == 6)
      xml = "<d:multistatus xmlns:d='DAV:'><d:response>";
    else if (mode == 7)
      xml = "<!DOCTYPE multistatus [<!ENTITY x 'bad'>]><d:multistatus xmlns:d='DAV:'/>";
    else if (mode == 8) {
      r->statusCode = 405;
      xml = "";
    } else if (mode == 9)
      xml = "<d:multistatus xmlns:d='DAV:'><d:error><d:number-of-matches-within-limits/></d:error></d:multistatus>";
    else if (mode == 10)
      xml = "<d:multistatus xmlns:d='DAV:'><d:response><d:href>recent.ics</d:href>"
            "<d:status>HTTP/1.1 503 Unavailable</d:status></d:response></d:multistatus>";
    else
      xml = mode == 3 ? "<d:multistatus "
                        "xmlns:d='DAV:'><d:response><d:href>item.ics</"
                        "d:href><d:propstat><d:prop><d:getetag>two</d:getetag></"
                        "d:prop><d:status>HTTP/1.1 200 "
                        "OK</d:status></d:propstat></d:response></d:multistatus>"
                      : "<d:multistatus "
                        "xmlns:d='DAV:'><d:response><d:href>item.ics</"
                        "d:href><d:propstat><d:prop><d:getetag>one</d:getetag></"
                        "d:prop><d:status>HTTP/1.1 200 "
                        "OK</d:status></d:propstat></d:response></d:multistatus>";
  }
  r->body = (unsigned char *)strdup(xml);
  r->bodyLength = strlen(xml);
  return 1;
}
static int available(RCCalendarStore *s)
{
  sqlite3_stmt *q = NULL;
  int n = -1;
  if (sqlite3_prepare_v2(s->db, "SELECT count(*) FROM available_events", -1, &q,
                         NULL) == SQLITE_OK &&
      sqlite3_step(q) == SQLITE_ROW)
    n = sqlite3_column_int(q, 0);
  sqlite3_finalize(q);
  return n;
}
static long long scalar(RCCalendarStore *s, const char *sql)
{
  sqlite3_stmt *q = NULL;
  long long n = -1;
  if (sqlite3_prepare_v2(s->db, sql, -1, &q, NULL) == SQLITE_OK && sqlite3_step(q) == SQLITE_ROW)
    n = sqlite3_column_int64(q, 0);
  sqlite3_finalize(q);
  return n;
}
static int publish(RCCalendarStore *s, RCError *e)
{
  long long generation = scalar(s, "SELECT generation FROM accounts WHERE username='history'");
  return RCCalendarStoreSQL(s, e, "BEGIN IMMEDIATE;"
      "UPDATE calendar_resources SET export_ical=raw_ical,export_etag=etag "
      "WHERE scope_excluded=0 AND remote_missing=0") &&
      RCCalendarStoreSnapshotWriteBases(s, generation, e) &&
      RCCalendarStoreSQL(s, e, "UPDATE accounts SET published_generation=generation "
                               "WHERE id=%lld;COMMIT", s->account);
}
#define CHECK(x)                                                                       \
  do {                                                                                 \
    if (!(x)) {                                                                        \
      fprintf(stderr, "DAV test line %d: %s\n", __LINE__, e.message);                  \
      goto done;                                                                       \
    }                                                                                  \
  } while (0)
static int testHistory(void)
{
  char path[] = "/tmp/rc-calendar-history-XXXXXX", start[17];
  int fd = mkstemp(path), ok = 0, before, i;
  long long oldID;
  struct stat large, small;
  RCError e;
  RCCalendarStore *s = NULL;
  RCCardDAVMirrorConfig config = {
      "https://example.test/", "history", "synthetic", "mock-ca", NULL, NULL, NULL};
  RCCardDAVMirrorResult result;
  if (fd < 0) return 0;
  close(fd);
  historyFixtures = 1; mode = 0; getCount = 0;
  CHECK(RCCalDAVHistoryStart("20260906", 2, start, &e) && !strcmp(start, "20240906T000000Z"));
  CHECK(RCCalDAVHistoryStart("20240229", 1, start, &e) && !strcmp(start, "20230228T000000Z"));
  CHECK(RCCalDAVHistoryStart("20400301", 2, start, &e) && !strcmp(start, "20380301T000000Z"));
  CHECK(!RCCalDAVHistoryStart("20260230", 2, start, &e));
  CHECK(!RCCalDAVHistoryStart("20260906", 3, start, &e));
  s = RCCalendarStoreOpen(path, "history", &e);
  CHECK(s);
  /* Fresh limited fetch downloads four resources, including a pre-window
     recurring master, its override, a future event and an overlapping all-day event. */
  CHECK(RCCalDAVMirrorFetchSince(&config, s, "20240906T000000Z", &result, &e));
  CHECK(reportCount == 1 && getCount == 4 && available(s) == 5);
  CHECK(scalar(s, "SELECT count(*) FROM calendar_resources WHERE uid='old'") == 0);
  CHECK(scalar(s, "SELECT count(*) FROM events WHERE uid='series'") == 2);
  CHECK(RCCalDAVMirrorFetch(&config, s, &result, &e));
  CHECK(getCount == 5 && available(s) == 6);
  oldID = scalar(s, "SELECT id FROM calendar_resources WHERE uid='old'");
  CHECK(oldID > 0 && publish(s, &e));
  /* Inflate the old cache to prove that pruning reclaims actual file pages. */
  CHECK(RCCalendarStoreSQL(s, &e, "UPDATE calendar_resources SET raw_ical=zeroblob(2097152) WHERE uid='old'"));
  CHECK(stat(path, &large) == 0);
  /* Rejected, malformed, mixed-status and truncated reports retain the old scope. */
  for (i = 2; i <= 10; i++) {
    if (i == 3 || i == 5) continue;
    mode = i;
    CHECK(!RCCalDAVMirrorFetchSince(&config, s, "20250906T000000Z", &result, &e));
    CHECK(available(s) == 6);
    CHECK(scalar(s, "SELECT length(raw_ical) FROM calendar_resources WHERE uid='old'") == 2097152);
  }
  mode = 0;
  CHECK(RCCalDAVMirrorFetchSince(&config, s, "20250906T000000Z", &result, &e));
  CHECK(available(s) == 3);
  CHECK(scalar(s, "SELECT count(*) FROM calendar_resources WHERE scope_excluded=1") == 3);
  CHECK(scalar(s, "SELECT count(*) FROM calendar_resources WHERE remote_missing=1") == 0);
  CHECK(!RCCalendarStorePruneHistory(s, &e)); /* Publication must finish first. */
  CHECK(publish(s, &e));
  CHECK(RCCalendarStorePruneHistory(s, &e));
  CHECK(stat(path, &small) == 0 && small.st_size < large.st_size / 2);
  CHECK(scalar(s, "SELECT length(raw_ical) FROM calendar_resources WHERE uid='old'") == 0);
  CHECK(scalar(s, "SELECT count(*) FROM events WHERE uid='old'") == 0);
  CHECK(scalar(s, "SELECT count(*) FROM write_bases") == 2);
  /* Retry after restart, then restore wider history with identical href/ETag.
     Purged resources must download again and retain their resource identities. */
  RCCalendarStoreClose(s); s = RCCalendarStoreOpen(path, "history", &e);
  CHECK(s && RCCalendarStorePruneHistory(s, &e));
  before = getCount;
  CHECK(RCCalDAVMirrorFetch(&config, s, &result, &e));
  CHECK(getCount == before + 3 && available(s) == 6);
  CHECK(scalar(s, "SELECT id FROM calendar_resources WHERE uid='old'") == oldID);
  /* An empty scoped response is a valid empty publication, never remote deletion. */
  mode = 1;
  CHECK(RCCalDAVMirrorFetchSince(&config, s, "20250906T000000Z", &result, &e));
  CHECK(available(s) == 0);
  CHECK(scalar(s, "SELECT count(*) FROM calendar_resources WHERE remote_missing=1") == 0);
  /* Unresolved writes protect their cached resources. Other accounts are never
     pruned by this account, even when their rows are also outside scope. */
  CHECK(RCCalendarStoreSQL(s, &e,
      "INSERT INTO write_operations(account_id,change_id,resource_key,href,kind,state,local_revision) "
      "SELECT %lld,'pending','resource-'||id,href,'update','uncertain',1 "
      "FROM calendar_resources WHERE uid='old';"
      "INSERT INTO accounts(username,sync_id) VALUES('other','other-sync');"
      "INSERT INTO calendars(account_id,url,sync_id) SELECT id,'https://other.test/','other-cal' "
      "FROM accounts WHERE username='other';"
      "INSERT INTO calendar_resources(calendar_id,href,uid,raw_ical,scope_excluded) "
      "SELECT id,'https://other.test/other.ics','other',X'010203',1 FROM calendars WHERE url='https://other.test/'",
      s->account));
  CHECK(publish(s, &e) && RCCalendarStorePruneHistory(s, &e));
  CHECK(scalar(s, "SELECT length(raw_ical) FROM calendar_resources WHERE uid='old'") > 0);
  CHECK(scalar(s, "SELECT length(raw_ical) FROM calendar_resources WHERE uid='other'") == 3);
  CHECK(scalar(s, "SELECT count(*) FROM write_operations WHERE state='uncertain'") == 1);
  CHECK(RCCalendarStoreSQL(s, &e, "UPDATE write_operations SET state='acknowledged'"));
  CHECK(RCCalendarStorePruneHistory(s, &e));
  CHECK(scalar(s, "SELECT length(raw_ical) FROM calendar_resources WHERE uid='old'") == 0);
  CHECK(scalar(s, "SELECT length(raw_ical) FROM calendar_resources WHERE uid='other'") == 3);
  ok = 1;
  puts("Calendar history queries, recurrence retention, scope rollback, restoration and disk compaction passed.");
done:
  RCCalendarStoreClose(s); unlink(path);
  historyFixtures = 0; mode = 0;
  return ok;
}
int main(void)
{
  char path[] = "/tmp/rc-caldav-XXXXXX";
  int fd = mkstemp(path), ok = 0, i;
  RCCalendarStore *s = NULL;
  RCError e;
  RCCardDAVMirrorConfig config = {
      "https://example.test/", "mock", "synthetic", "mock-ca", NULL, NULL, NULL};
  RCCardDAVMirrorResult result;
  if (fd < 0)
    return 1;
  close(fd);
  s = RCCalendarStoreOpen(path, "mock", &e);
  CHECK(s);
  CHECK(RCCalDAVMirrorFetch(&config, s, &result, &e));
  CHECK(available(s) == 1 && getCount == 1);
  CHECK(RCCalDAVMirrorFetch(&config, s, &result, &e));
  CHECK(getCount == 1 && result.unchangedResourceCount == 1);
  for (i = 2; i <= 7; i++) {
    if (i == 5)
      continue;
    mode = i;
    CHECK(!RCCalDAVMirrorFetch(&config, s, &result, &e));
    CHECK(available(s) == 1);
  }
  mode = 1;
  CHECK(RCCalDAVMirrorFetch(&config, s, &result, &e));
  CHECK(available(s) == 0);
  mode = 0;
  CHECK(RCCalDAVMirrorFetch(&config, s, &result, &e));
  CHECK(available(s) == 1);
  mode = 5;
  CHECK(RCCalDAVMirrorFetch(&config, s, &result, &e));
  CHECK(available(s) == 0);
  CHECK(testHistory());
  ok = 1;
  puts("CalDAV discovery/inventory/failure tests passed.");
done:
  RCCalendarStoreClose(s);
  unlink(path);
  return ok ? 0 : 1;
}
