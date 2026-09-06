#include "RCCalDAVMirror.h"
#include <libxml/uri.h>
#include <libxml/xmlmemory.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int mode, getCount;
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
#define CHECK(x)                                                                       \
  do {                                                                                 \
    if (!(x)) {                                                                        \
      fprintf(stderr, "DAV test line %d: %s\n", __LINE__, e.message);                  \
      goto done;                                                                       \
    }                                                                                  \
  } while (0)
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
  ok = 1;
  puts("CalDAV discovery/inventory/failure tests passed.");
done:
  RCCalendarStoreClose(s);
  unlink(path);
  return ok ? 0 : 1;
}
