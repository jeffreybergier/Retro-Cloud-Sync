#include "RCDAVClient.h"
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static const char kDAVNamespace[] = "DAV:";

static const char kCollectionsRequest[] =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    "<d:propfind xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\" "
    "xmlns:a=\"http://apple.com/ns/ical/\"><d:prop>"
    "<d:resourcetype/><d:displayname/><d:sync-token/><d:supported-report-set/><c:calendar-description/>"
    "<a:calendar-color/><c:supported-calendar-component-set/>"
    "</d:prop></d:propfind>";

static const char kInventoryRequest[] = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                                        "<d:propfind xmlns:d=\"DAV:\"><d:prop>"
                                        "<d:resourcetype/><d:getetag/>"
                                        "</d:prop></d:propfind>";

static xmlNodePtr RCSuccessfulProperty(xmlNodePtr responseNode, const char *name,
                                       const char *namespaceURL);

static char *RCCopyString(const char *string)
{
  size_t length;
  char *copy;
  if (string == NULL)
    return NULL;
  length = strlen(string);
  copy = (char *)malloc(length + 1);
  if (copy != NULL)
    memcpy(copy, string, length + 1);
  return copy;
}

static int RCNodeIs(xmlNodePtr node, const char *name, const char *namespaceURL)
{
  return node != NULL && node->type == XML_ELEMENT_NODE &&
         xmlStrcmp(node->name, (const xmlChar *)name) == 0 && node->ns != NULL &&
         node->ns->href != NULL &&
         xmlStrcmp(node->ns->href, (const xmlChar *)namespaceURL) == 0;
}

static xmlNodePtr RCFindChild(xmlNodePtr parent, const char *name,
                              const char *namespaceURL)
{
  xmlNodePtr child;
  for (child = parent == NULL ? NULL : parent->children; child != NULL;
       child = child->next) {
    if (RCNodeIs(child, name, namespaceURL))
      return child;
  }
  return NULL;
}

static xmlNodePtr RCFindDescendant(xmlNodePtr parent, const char *name,
                                   const char *namespaceURL)
{
  xmlNodePtr child;
  for (child = parent == NULL ? NULL : parent->children; child != NULL;
       child = child->next) {
    xmlNodePtr found;
    if (RCNodeIs(child, name, namespaceURL))
      return child;
    found = RCFindDescendant(child, name, namespaceURL);
    if (found != NULL)
      return found;
  }
  return NULL;
}

static char *RCNodeText(xmlNodePtr node)
{
  xmlChar *content;
  char *copy;
  if (node == NULL)
    return NULL;
  content = xmlNodeGetContent(node);
  if (content == NULL)
    return NULL;
  copy = RCCopyString((const char *)content);
  xmlFree(content);
  return copy;
}

static xmlDocPtr RCParseXML(const RCHTTPResponse *response, RCError *error)
{
  xmlDocPtr document;
  xmlNodePtr root;
  if (response->bodyLength > (size_t)0x7fffffff) {
    RCErrorSet(error, 1, "DAV XML response is too large");
    return NULL;
  }
  document = xmlReadMemory((const char *)response->body, (int)response->bodyLength,
                           response->effectiveURL, NULL,
                           XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING);
  if (document == NULL) {
    RCErrorSet(error, 1, "Could not parse DAV XML response");
    return NULL;
  }
  if (document->intSubset != NULL || document->extSubset != NULL) {
    xmlFreeDoc(document);
    RCErrorSet(error, 1, "DAV XML must not contain a DTD");
    return NULL;
  }
  root = xmlDocGetRootElement(document);
  if (!RCNodeIs(root, "multistatus", kDAVNamespace)) {
    xmlFreeDoc(document);
    RCErrorSet(error, 1, "DAV response is not a multistatus document");
    return NULL;
  }
  return document;
}

static int RCRequireMultiStatus(const RCHTTPResponse *response, const char *operation,
                                RCError *error)
{
  if (response->statusCode != 207) {
    RCErrorSet(error, (int)response->statusCode, "%s returned HTTP %ld", operation,
               response->statusCode);
    return 0;
  }
  return 1;
}

int RCDAVDiscoverHref(RCHTTPClient *client, const char *url, const char *requestBody,
                      const char *propertyName, const char *propertyNamespace,
                      char **resultURL, RCError *error)
{
  RCHTTPResponse response;
  xmlDocPtr document = NULL;
  xmlNodePtr responseNode;
  xmlNodePtr property;
  xmlNodePtr href;
  char *hrefText = NULL;
  int success = 0;

  RCHTTPResponseInit(&response);
  if (!RCHTTPClientRequest(client, "PROPFIND", url, "0",
                           "application/xml; charset=utf-8", requestBody,
                           strlen(requestBody), &response, error) ||
      !RCRequireMultiStatus(&response, "DAV discovery", error))
    goto finished;
  document = RCParseXML(&response, error);
  if (document == NULL)
    goto finished;
  property = NULL;
  for (responseNode = xmlDocGetRootElement(document)->children; responseNode != NULL;
       responseNode = responseNode->next) {
    if (!RCNodeIs(responseNode, "response", kDAVNamespace))
      continue;
    property = RCSuccessfulProperty(responseNode, propertyName, propertyNamespace);
    if (property != NULL)
      break;
  }
  href = RCFindDescendant(property, "href", kDAVNamespace);
  hrefText = RCNodeText(href);
  if (hrefText == NULL) {
    RCErrorSet(error, 1, "DAV discovery response omitted %s", propertyName);
    goto finished;
  }
  success = RCURLResolve(response.effectiveURL, hrefText, resultURL, error);

finished:
  free(hrefText);
  if (document != NULL)
    xmlFreeDoc(document);
  RCHTTPResponseClear(&response);
  return success;
}

static int RCPropertyStatusIsSuccessful(xmlNodePtr propstat)
{
  char *status = RCNodeText(RCFindChild(propstat, "status", kDAVNamespace));
  int successful = status != NULL && strstr(status, " 200 ") != NULL;
  free(status);
  return successful;
}

static xmlNodePtr RCSuccessfulProperty(xmlNodePtr responseNode, const char *name,
                                       const char *namespaceURL)
{
  xmlNodePtr propstat;
  for (propstat = responseNode->children; propstat != NULL; propstat = propstat->next) {
    xmlNodePtr prop;
    if (!RCNodeIs(propstat, "propstat", kDAVNamespace) ||
        !RCPropertyStatusIsSuccessful(propstat))
      continue;
    prop = RCFindChild(propstat, "prop", kDAVNamespace);
    prop = RCFindChild(prop, name, namespaceURL);
    if (prop != NULL)
      return prop;
  }
  return NULL;
}

static int RCAppendCollection(RCDAVCollection **collections, size_t *count, char *url,
                              char *displayName, RCError *error)
{
  RCDAVCollection *newCollections =
      (RCDAVCollection *)realloc(*collections, (*count + 1) * sizeof(**collections));
  if (newCollections == NULL) {
    RCErrorSet(error, 1, "Out of memory listing DAV collections");
    return 0;
  }
  *collections = newCollections;
  memset(&newCollections[*count], 0, sizeof(newCollections[*count]));
  newCollections[*count].url = url;
  newCollections[*count].displayName = displayName;
  (*count)++;
  return 1;
}

int RCDAVListCollections(RCHTTPClient *client, const char *homeURL, const char *type,
                         const char *typeNamespace, RCDAVCollection **collections,
                         size_t *count, RCError *error)
{
  RCHTTPResponse response;
  xmlDocPtr document = NULL;
  xmlNodePtr node;
  int success = 0;

  *collections = NULL;
  *count = 0;
  RCHTTPResponseInit(&response);
  if (!RCHTTPClientRequest(client, "PROPFIND", homeURL, "1",
                           "application/xml; charset=utf-8", kCollectionsRequest,
                           strlen(kCollectionsRequest), &response, error) ||
      !RCRequireMultiStatus(&response, "Collection listing", error))
    goto finished;
  document = RCParseXML(&response, error);
  if (document == NULL)
    goto finished;
  for (node = xmlDocGetRootElement(document)->children; node != NULL;
       node = node->next) {
    xmlNodePtr resourceType;
    xmlNodePtr href;
    char *hrefText;
    char *url = NULL;
    char *displayName;
    if (!RCNodeIs(node, "response", kDAVNamespace))
      continue;
    resourceType = RCSuccessfulProperty(node, "resourcetype", kDAVNamespace);
    if (resourceType == NULL) {
      RCErrorSet(error, 1, "Collection listing omitted a successful resource type");
      goto finished;
    }
    if (RCFindChild(resourceType, type, typeNamespace) == NULL)
      continue;
    href = RCFindChild(node, "href", kDAVNamespace);
    hrefText = RCNodeText(href);
    displayName = RCNodeText(RCSuccessfulProperty(node, "displayname", kDAVNamespace));
    if (hrefText == NULL ||
        !RCURLResolve(response.effectiveURL, hrefText, &url, error) ||
        !RCAppendCollection(collections, count, url, displayName, error)) {
      free(hrefText);
      free(url);
      free(displayName);
      goto finished;
    }
    free(hrefText);
    (*collections)[*count - 1].description = RCNodeText(RCSuccessfulProperty(
        node, "calendar-description", "urn:ietf:params:xml:ns:caldav"));
    (*collections)[*count - 1].color = RCNodeText(
        RCSuccessfulProperty(node, "calendar-color", "http://apple.com/ns/ical/"));
    (*collections)[*count - 1].syncToken = RCNodeText(
        RCSuccessfulProperty(node, "sync-token", kDAVNamespace));
    if ((*collections)[*count - 1].syncToken &&
        !*(*collections)[*count - 1].syncToken) {
      free((*collections)[*count - 1].syncToken);
      (*collections)[*count - 1].syncToken = NULL;
    }
    (*collections)[*count - 1].supportsSync =
        (*collections)[*count - 1].syncToken != NULL ||
        RCFindDescendant(RCSuccessfulProperty(node, "supported-report-set", kDAVNamespace),
                         "sync-collection", kDAVNamespace) != NULL;
  }
  success = 1;

finished:
  if (!success) {
    size_t index;
    for (index = 0; index < *count; index++) {
      free((*collections)[index].url);
      free((*collections)[index].displayName);
      free((*collections)[index].description);
      free((*collections)[index].color);
      free((*collections)[index].syncToken);
    }
    free(*collections);
    *collections = NULL;
    *count = 0;
  }
  if (document != NULL)
    xmlFreeDoc(document);
  RCHTTPResponseClear(&response);
  return success;
}

static int RCAppendResource(RCDAVResource **resources, size_t *count, char *url,
                            char *etag, RCError *error)
{
  RCDAVResource *newResources =
      (RCDAVResource *)realloc(*resources, (*count + 1) * sizeof(**resources));
  if (newResources == NULL) {
    RCErrorSet(error, 1, "Out of memory listing DAV resources");
    return 0;
  }
  *resources = newResources;
  newResources[*count].url = url;
  newResources[*count].etag = etag;
  (*count)++;
  return 1;
}

static int RCListResources(RCHTTPClient *client, const char *collectionURL,
                           const char *method, const char *request,
                           RCDAVResource **resources, size_t *count, RCError *error)
{
  RCHTTPResponse response;
  xmlDocPtr document = NULL;
  xmlNodePtr node;
  int success = 0;
  *resources = NULL;
  *count = 0;
  RCHTTPResponseInit(&response);
  if (!RCHTTPClientRequest(client, method, collectionURL, "1",
                           "application/xml; charset=utf-8", request,
                           strlen(request), &response, error) ||
      !RCRequireMultiStatus(&response, "Resource inventory", error))
    goto finished;
  document = RCParseXML(&response, error);
  if (document == NULL)
    goto finished;
  if (RCFindDescendant(xmlDocGetRootElement(document), "error", kDAVNamespace)) {
    RCErrorSet(error, 1, "DAV inventory contains an error or truncated result");
    goto finished;
  }
  for (node = xmlDocGetRootElement(document)->children; node != NULL;
       node = node->next) {
    xmlNodePtr resourceType;
    char *hrefText;
    char *url = NULL;
    char *etag;
    if (!RCNodeIs(node, "response", kDAVNamespace))
      continue;
    if (RCFindChild(node, "status", kDAVNamespace) &&
        !RCPropertyStatusIsSuccessful(node)) {
      RCErrorSet(error, 1, "DAV inventory contains an unsuccessful resource response");
      goto finished;
    }
    resourceType = RCSuccessfulProperty(node, "resourcetype", kDAVNamespace);
    if (resourceType != NULL &&
        RCFindChild(resourceType, "collection", kDAVNamespace) != NULL)
      continue;
    hrefText = RCNodeText(RCFindChild(node, "href", kDAVNamespace));
    etag = RCNodeText(RCSuccessfulProperty(node, "getetag", kDAVNamespace));
    if (hrefText == NULL || etag == NULL ||
        !RCURLResolve(response.effectiveURL, hrefText, &url, error) ||
        !RCAppendResource(resources, count, url, etag, error)) {
      free(hrefText);
      free(url);
      free(etag);
      goto finished;
    }
    free(hrefText);
  }
  success = 1;

finished:
  if (!success) {
    size_t index;
    for (index = 0; index < *count; index++) {
      free((*resources)[index].url);
      free((*resources)[index].etag);
    }
    free(*resources);
    *resources = NULL;
    *count = 0;
  }
  if (document != NULL)
    xmlFreeDoc(document);
  RCHTTPResponseClear(&response);
  return success;
}

int RCDAVListResources(RCHTTPClient *client, const char *url,
                       RCDAVResource **resources, size_t *count, RCError *error)
{
  return RCListResources(client, url, "PROPFIND", kInventoryRequest,
                         resources, count, error);
}

int RCDAVListCalendarResourcesSince(RCHTTPClient *client, const char *url,
                                    const char *start, RCDAVResource **resources,
                                    size_t *count, RCError *error)
{
  char request[512];
  size_t i;
  *resources = NULL;
  *count = 0;
  /* Validate before embedding a caller-supplied value in XML. */
  if (!start || strlen(start) != 16 || start[8] != 'T' || start[15] != 'Z')
    goto invalid;
  for (i = 0; i < 15; i++)
    if (i != 8 && (start[i] < '0' || start[i] > '9')) goto invalid;
  snprintf(request, sizeof(request),
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
      "<c:calendar-query xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">"
      "<d:prop><d:getetag/></d:prop><c:filter>"
      "<c:comp-filter name=\"VCALENDAR\"><c:comp-filter name=\"VEVENT\">"
      "<c:time-range start=\"%s\"/>"
      "</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>", start);
  return RCListResources(client, url, "REPORT", request, resources, count, error);
invalid:
  RCErrorSet(error, 1, "Calendar history start must be a UTC date-time");
  return 0;
}

void RCDAVFreeCollections(RCDAVCollection *collections, size_t count)
{
  size_t index;
  for (index = 0; index < count; index++) {
    free(collections[index].url);
    free(collections[index].displayName);
    free(collections[index].description);
    free(collections[index].color);
    free(collections[index].syncToken);
  }
  free(collections);
}

void RCDAVFreeResources(RCDAVResource *resources, size_t count)
{
  size_t index;
  for (index = 0; index < count; index++) {
    free(resources[index].url);
    free(resources[index].etag);
  }
  free(resources);
}

/* Sync responses have different semantics from a full inventory: member 404s
   are deletions, and a collection 507 is a continuation, never an empty scan. */
/* Some servers include collection properties in sync reports, and iCloud
   spells that href without the collection URL's trailing slash. Compare only
   that optional slash; member URLs must keep their exact identity. */
static int RCIsSyncCollectionURL(const char *href, const char *collectionURL)
{
  size_t hrefLength = strlen(href), collectionLength = strlen(collectionURL);
  if (!strcmp(href, collectionURL)) return 1;
  if (strchr(href, '?') || strchr(href, '#') ||
      strchr(collectionURL, '?') || strchr(collectionURL, '#')) return 0;
  if (hrefLength && href[hrefLength - 1] == '/') hrefLength--;
  if (collectionLength && collectionURL[collectionLength - 1] == '/') collectionLength--;
  return hrefLength == collectionLength && !strncmp(href, collectionURL, hrefLength);
}

int RCDAVSyncCollection(RCHTTPClient *client, const char *url, const char *token,
                        RCDAVSyncCallback callback, void *context,
                        char **nextToken, RCError *error)
{
  char *tokens[1025];
  size_t page, tokenCount = 0, i;
  int result = RCDAVSyncFailed;
  *nextToken = NULL;
  memset(tokens, 0, sizeof(tokens));
  tokens[tokenCount++] = RCCopyString(token ? token : "");
  if (!tokens[0]) goto exhausted;
  for (page = 0; page < 1024; page++) {
    if (RCCheckCancellation(error)) goto exhausted;
    RCHTTPResponse response;
    xmlDocPtr doc = NULL;
    xmlChar *escaped = NULL;
    xmlNodePtr root, node;
    RCDAVResource *changes = NULL;
    size_t count = 0;
    char *request = NULL, *returned = NULL;
    int more = 0, tokenNodes = 0, pageOK = 0;
    RCHTTPResponseInit(&response);
    if (strlen(tokens[tokenCount - 1]) > 16384) goto page_failed;
    escaped = xmlEncodeSpecialChars(NULL, (const xmlChar *)tokens[tokenCount - 1]);
    if (!escaped) goto page_failed;
    request = malloc(strlen((const char *)escaped) + 384);
    if (!request) goto page_failed;
    sprintf(request, "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        "<d:sync-collection xmlns:d=\"DAV:\"><d:sync-token>%s</d:sync-token>"
        "<d:sync-level>1</d:sync-level><d:limit><d:nresults>200</d:nresults></d:limit>"
        "<d:prop><d:getetag/></d:prop></d:sync-collection>", (const char *)escaped);
    if (!RCHTTPClientRequest(client, "REPORT", url, "0", "application/xml; charset=utf-8",
                             request, strlen(request), &response, error)) goto page_failed;
    if (response.statusCode == 405 || response.statusCode == 501) {
      result = RCDAVSyncFallback; goto page_failed;
    }
    if (response.bodyLength > (size_t)0x7fffffff) goto page_failed;
    doc = xmlReadMemory((const char *)response.body, (int)response.bodyLength,
                        response.effectiveURL, NULL,
                        XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING);
    if (!doc || doc->intSubset || doc->extSubset) goto page_failed;
    root = xmlDocGetRootElement(doc);
    if (RCNodeIs(root, "error", kDAVNamespace)) {
      if (((response.statusCode == 403 || response.statusCode == 409) &&
           (RCFindChild(root, "valid-sync-token", kDAVNamespace) ||
            RCFindChild(root, "supported-report", kDAVNamespace))) ||
          (response.statusCode == 507 &&
           RCFindChild(root, "number-of-matches-within-limits", kDAVNamespace)))
        result = RCDAVSyncFallback;
      goto page_failed;
    }
    if (response.statusCode != 207 || !RCNodeIs(root, "multistatus", kDAVNamespace))
      goto page_failed;
    for (node = root->children; node; node = node->next) {
      char *href, *resolved = NULL, *status, *etag;
      int code = 0, isCollection;
      if (RCNodeIs(node, "sync-token", kDAVNamespace)) {
        if (++tokenNodes != 1) goto page_failed;
        returned = RCNodeText(node);
        continue;
      }
      if (RCNodeIs(node, "error", kDAVNamespace)) goto page_failed;
      if (!RCNodeIs(node, "response", kDAVNamespace)) continue;
      href = RCNodeText(RCFindChild(node, "href", kDAVNamespace));
      if (!href || !*href || !RCURLResolve(response.effectiveURL, href, &resolved, error)) {
        free(href); free(resolved); goto page_failed;
      }
      free(href);
      status = RCNodeText(RCFindChild(node, "status", kDAVNamespace));
      if (status) sscanf(status, "HTTP/%*s %d", &code);
      isCollection = RCIsSyncCollectionURL(resolved, response.effectiveURL);
      if (code == 507 && isCollection && !more &&
          !RCFindChild(node, "propstat", kDAVNamespace)) {
        more = 1; free(status); free(resolved); continue;
      }
      if (isCollection && !status &&
          !RCFindDescendant(node, "error", kDAVNamespace) &&
          RCSuccessfulProperty(node, "getetag", kDAVNamespace)) {
        free(resolved); continue;
      }
      if ((status && (code != 404 || RCFindChild(node, "propstat", kDAVNamespace))) ||
          isCollection ||
          RCFindDescendant(node, "error", kDAVNamespace)) {
        free(status); free(resolved); goto page_failed;
      }
      etag = code == 404 ? NULL : RCNodeText(RCSuccessfulProperty(node, "getetag", kDAVNamespace));
      free(status);
      if (code != 404 && (!etag || !*etag)) {
        free(etag); free(resolved); goto page_failed;
      }
      for (i = 0; i < count; i++) if (!strcmp(changes[i].url, resolved)) break;
      if (i != count || !RCAppendResource(&changes, &count, resolved, etag, error)) {
        free(etag); free(resolved); goto page_failed;
      }
    }
    if (tokenNodes != 1 || !returned || !*returned || strlen(returned) > 16384 ||
        (more && !count)) goto page_failed;
    /* A final empty response may return the same token; a continuation must
       advance and must not cycle, including after several successful pages. */
    if (more || count) {
      for (i = 0; i < tokenCount; i++)
        if (!strcmp(returned, tokens[i])) goto page_failed;
    }
    if (callback && !callback(changes, count, context, error)) goto page_failed;
    tokens[tokenCount++] = returned; returned = NULL;
    pageOK = 1;
    if (!more) {
      *nextToken = tokens[--tokenCount]; tokens[tokenCount] = NULL;
      result = RCDAVSyncComplete;
    }
page_failed:
    free(returned); free(request); xmlFree(escaped); xmlFreeDoc(doc);
    RCDAVFreeResources(changes, count); RCHTTPResponseClear(&response);
    if (!pageOK || result == RCDAVSyncComplete) break;
  }
exhausted:
  for (i = 0; i < tokenCount; i++) free(tokens[i]);
  if (result == RCDAVSyncFailed && (!error || !error->code))
    RCErrorSet(error, 1, "Incomplete, invalid, or excessive DAV sync response");
  return result;
}
