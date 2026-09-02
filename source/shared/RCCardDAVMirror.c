#include "RCCardDAVMirror.h"

#include "RCVCard.h"

#include <libxml/parser.h>
#include <libxml/tree.h>

#include <stdlib.h>
#include <string.h>
#include <strings.h>

static const char kDAVNamespace[] = "DAV:";
static const char kCardDAVNamespace[] = "urn:ietf:params:xml:ns:carddav";

static const char kPrincipalRequest[] =
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
  "<d:propfind xmlns:d=\"DAV:\"><d:prop>"
  "<d:current-user-principal/>"
  "</d:prop></d:propfind>";

static const char kHomeRequest[] =
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
  "<d:propfind xmlns:d=\"DAV:\" "
  "xmlns:c=\"urn:ietf:params:xml:ns:carddav\"><d:prop>"
  "<c:addressbook-home-set/>"
  "</d:prop></d:propfind>";

static const char kCollectionsRequest[] =
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
  "<d:propfind xmlns:d=\"DAV:\" "
  "xmlns:c=\"urn:ietf:params:xml:ns:carddav\"><d:prop>"
  "<d:resourcetype/><d:displayname/>"
  "</d:prop></d:propfind>";

static const char kInventoryRequest[] =
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
  "<d:propfind xmlns:d=\"DAV:\"><d:prop>"
  "<d:resourcetype/><d:getetag/>"
  "</d:prop></d:propfind>";

typedef struct {
  char *url;
  char *displayName;
} RCCollection;

typedef struct {
  char *url;
  char *etag;
} RCResource;

static xmlNodePtr RCSuccessfulProperty(xmlNodePtr responseNode,
                                       const char *name,
                                       const char *namespaceURL);

static char *RCCopyString(const char *string)
{
  size_t length;
  char *copy;
  if (string == NULL) return NULL;
  length = strlen(string);
  copy = (char *)malloc(length + 1);
  if (copy != NULL) memcpy(copy, string, length + 1);
  return copy;
}

static void RCProgress(const RCCardDAVMirrorConfig *config,
                       const char *message)
{
  if (config->progress != NULL) {
    config->progress(message, config->progressContext);
  }
}

static int RCNodeIs(xmlNodePtr node, const char *name,
                    const char *namespaceURL)
{
  return node != NULL && node->type == XML_ELEMENT_NODE &&
      xmlStrcmp(node->name, (const xmlChar *)name) == 0 &&
      node->ns != NULL && node->ns->href != NULL &&
      xmlStrcmp(node->ns->href, (const xmlChar *)namespaceURL) == 0;
}

static xmlNodePtr RCFindChild(xmlNodePtr parent, const char *name,
                              const char *namespaceURL)
{
  xmlNodePtr child;
  for (child = parent == NULL ? NULL : parent->children; child != NULL;
       child = child->next) {
    if (RCNodeIs(child, name, namespaceURL)) return child;
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
    if (RCNodeIs(child, name, namespaceURL)) return child;
    found = RCFindDescendant(child, name, namespaceURL);
    if (found != NULL) return found;
  }
  return NULL;
}

static char *RCNodeText(xmlNodePtr node)
{
  xmlChar *content;
  char *copy;
  if (node == NULL) return NULL;
  content = xmlNodeGetContent(node);
  if (content == NULL) return NULL;
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
  document = xmlReadMemory((const char *)response->body,
                           (int)response->bodyLength,
                           response->effectiveURL, NULL,
                           XML_PARSE_NONET | XML_PARSE_NOERROR |
                           XML_PARSE_NOWARNING);
  if (document == NULL) {
    RCErrorSet(error, 1, "Could not parse DAV XML response");
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

static int RCRequireMultiStatus(const RCHTTPResponse *response,
                                const char *operation, RCError *error)
{
  if (response->statusCode != 207) {
    RCErrorSet(error, (int)response->statusCode,
               "%s returned HTTP %ld", operation, response->statusCode);
    return 0;
  }
  return 1;
}

static int RCDiscoverHref(RCHTTPClient *client, const char *url,
                          const char *requestBody, const char *propertyName,
                          const char *propertyNamespace, char **resultURL,
                          RCError *error)
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
      "application/xml; charset=utf-8", requestBody, strlen(requestBody),
      &response, error) || !RCRequireMultiStatus(&response, "DAV discovery",
                                                 error)) goto finished;
  document = RCParseXML(&response, error);
  if (document == NULL) goto finished;
  property = NULL;
  for (responseNode = xmlDocGetRootElement(document)->children;
       responseNode != NULL; responseNode = responseNode->next) {
    if (!RCNodeIs(responseNode, "response", kDAVNamespace)) continue;
    property = RCSuccessfulProperty(responseNode, propertyName,
                                    propertyNamespace);
    if (property != NULL) break;
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
  if (document != NULL) xmlFreeDoc(document);
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

static xmlNodePtr RCSuccessfulProperty(xmlNodePtr responseNode,
                                       const char *name,
                                       const char *namespaceURL)
{
  xmlNodePtr propstat;
  for (propstat = responseNode->children; propstat != NULL;
       propstat = propstat->next) {
    xmlNodePtr prop;
    if (!RCNodeIs(propstat, "propstat", kDAVNamespace) ||
        !RCPropertyStatusIsSuccessful(propstat)) continue;
    prop = RCFindChild(propstat, "prop", kDAVNamespace);
    prop = RCFindChild(prop, name, namespaceURL);
    if (prop != NULL) return prop;
  }
  return NULL;
}

static int RCAppendCollection(RCCollection **collections, size_t *count,
                              char *url, char *displayName, RCError *error)
{
  RCCollection *newCollections = (RCCollection *)realloc(
      *collections, (*count + 1) * sizeof(**collections));
  if (newCollections == NULL) {
    RCErrorSet(error, 1, "Out of memory listing address books");
    return 0;
  }
  *collections = newCollections;
  newCollections[*count].url = url;
  newCollections[*count].displayName = displayName;
  (*count)++;
  return 1;
}

static int RCListCollections(RCHTTPClient *client, const char *homeURL,
                             RCCollection **collections, size_t *count,
                             RCError *error)
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
      !RCRequireMultiStatus(&response, "Address-book listing", error))
    goto finished;
  document = RCParseXML(&response, error);
  if (document == NULL) goto finished;
  for (node = xmlDocGetRootElement(document)->children; node != NULL;
       node = node->next) {
    xmlNodePtr resourceType;
    xmlNodePtr href;
    char *hrefText;
    char *url = NULL;
    char *displayName;
    if (!RCNodeIs(node, "response", kDAVNamespace)) continue;
    resourceType = RCSuccessfulProperty(node, "resourcetype", kDAVNamespace);
    if (RCFindChild(resourceType, "addressbook", kCardDAVNamespace) == NULL)
      continue;
    href = RCFindChild(node, "href", kDAVNamespace);
    hrefText = RCNodeText(href);
    displayName = RCNodeText(RCSuccessfulProperty(node, "displayname",
                                                  kDAVNamespace));
    if (hrefText == NULL || !RCURLResolve(response.effectiveURL, hrefText,
                                          &url, error) ||
        !RCAppendCollection(collections, count, url, displayName, error)) {
      free(hrefText);
      free(url);
      free(displayName);
      goto finished;
    }
    free(hrefText);
  }
  if (*count == 0) {
    RCErrorSet(error, 1, "No CardDAV address-book collections were found");
    goto finished;
  }
  success = 1;

finished:
  if (!success) {
    size_t index;
    for (index = 0; index < *count; index++) {
      free((*collections)[index].url);
      free((*collections)[index].displayName);
    }
    free(*collections);
    *collections = NULL;
    *count = 0;
  }
  if (document != NULL) xmlFreeDoc(document);
  RCHTTPResponseClear(&response);
  return success;
}

static int RCAppendResource(RCResource **resources, size_t *count,
                            char *url, char *etag, RCError *error)
{
  RCResource *newResources = (RCResource *)realloc(
      *resources, (*count + 1) * sizeof(**resources));
  if (newResources == NULL) {
    RCErrorSet(error, 1, "Out of memory listing CardDAV resources");
    return 0;
  }
  *resources = newResources;
  newResources[*count].url = url;
  newResources[*count].etag = etag;
  (*count)++;
  return 1;
}

static int RCListResources(RCHTTPClient *client, const char *collectionURL,
                           RCResource **resources, size_t *count,
                           RCError *error)
{
  RCHTTPResponse response;
  xmlDocPtr document = NULL;
  xmlNodePtr node;
  int success = 0;
  *resources = NULL;
  *count = 0;
  RCHTTPResponseInit(&response);
  if (!RCHTTPClientRequest(client, "PROPFIND", collectionURL, "1",
      "application/xml; charset=utf-8", kInventoryRequest,
      strlen(kInventoryRequest), &response, error) ||
      !RCRequireMultiStatus(&response, "Contact inventory", error)) goto finished;
  document = RCParseXML(&response, error);
  if (document == NULL) goto finished;
  for (node = xmlDocGetRootElement(document)->children; node != NULL;
       node = node->next) {
    xmlNodePtr resourceType;
    char *hrefText;
    char *url = NULL;
    char *etag;
    if (!RCNodeIs(node, "response", kDAVNamespace)) continue;
    resourceType = RCSuccessfulProperty(node, "resourcetype", kDAVNamespace);
    if (resourceType != NULL &&
        RCFindChild(resourceType, "collection", kDAVNamespace) != NULL) continue;
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
  if (document != NULL) xmlFreeDoc(document);
  RCHTTPResponseClear(&response);
  return success;
}

static void RCFreeCollections(RCCollection *collections, size_t count)
{
  size_t index;
  for (index = 0; index < count; index++) {
    free(collections[index].url);
    free(collections[index].displayName);
  }
  free(collections);
}

static void RCFreeResources(RCResource *resources, size_t count)
{
  size_t index;
  for (index = 0; index < count; index++) {
    free(resources[index].url);
    free(resources[index].etag);
  }
  free(resources);
}

static int RCFetchCollection(const RCCardDAVMirrorConfig *config,
                             RCHTTPClient *client, RCContactStore *store,
                             const RCCollection *collection,
                             long long runIdentifier,
                             RCCardDAVMirrorResult *result, RCError *error)
{
  RCResource *resources = NULL;
  size_t resourceCount = 0;
  size_t index;
  long long collectionIdentifier;
  int success = 0;

  RCProgress(config, "Listing contacts");
  if (!RCContactStoreGetCollection(store, collection->url,
                                   collection->displayName,
                                   &collectionIdentifier, error) ||
      !RCListResources(client, collection->url, &resources, &resourceCount,
                       error)) goto finished;
  result->listedResourceCount += (long)resourceCount;
  for (index = 0; index < resourceCount; index++) {
    int current;
    if (!RCContactStoreResourceIsCurrent(store, collectionIdentifier,
        resources[index].url, resources[index].etag, &current, error))
      goto finished;
    if (current) {
      if (!RCContactStoreMarkSeen(store, collectionIdentifier,
          resources[index].url, runIdentifier, error)) goto finished;
      result->unchangedResourceCount++;
    } else {
      RCHTTPResponse response;
      RCVCardDocument document;
      const char *etag;
      RCHTTPResponseInit(&response);
      RCVCardDocumentInit(&document);
      RCProgress(config, "Downloading changed contact");
      if (!RCHTTPClientRequest(client, "GET", resources[index].url, NULL,
          NULL, NULL, 0, &response, error)) {
        RCHTTPResponseClear(&response);
        goto finished;
      }
      if (response.statusCode != 200) {
        RCErrorSet(error, (int)response.statusCode,
                   "Contact GET returned HTTP %ld", response.statusCode);
        RCHTTPResponseClear(&response);
        goto finished;
      }
      if (!RCVCardParse(response.body, response.bodyLength, &document, error)) {
        RCHTTPResponseClear(&response);
        goto finished;
      }
      etag = response.etag != NULL ? response.etag : resources[index].etag;
      if (!RCContactStoreSaveVCard(store, collectionIdentifier, runIdentifier,
          resources[index].url, etag, response.body, response.bodyLength,
          &document, error)) {
        RCVCardDocumentClear(&document);
        RCHTTPResponseClear(&response);
        goto finished;
      }
      result->downloadedResourceCount++;
      RCVCardDocumentClear(&document);
      RCHTTPResponseClear(&response);
    }
  }
  if (!RCContactStoreFinishCollection(store, collectionIdentifier,
                                      runIdentifier, error)) goto finished;
  success = 1;

finished:
  RCFreeResources(resources, resourceCount);
  return success;
}

int RCCardDAVMirrorFetch(const RCCardDAVMirrorConfig *config,
                         RCContactStore *store, RCCardDAVMirrorResult *result,
                         RCError *error)
{
  RCHTTPClientConfig httpConfig;
  RCHTTPClient *client = NULL;
  char *principalURL = NULL;
  char *homeURL = NULL;
  RCCollection *collections = NULL;
  size_t collectionCount = 0;
  size_t index;
  long long runIdentifier = 0;
  int runStarted = 0;
  int success = 0;
  RCError finishError;
  RCError localError;

  if (error == NULL) error = &localError;
  RCErrorClear(error);
  if (result == NULL) {
    RCErrorSet(error, 1, "CardDAV mirror result is missing");
    return 0;
  }
  memset(result, 0, sizeof(*result));
  if (config == NULL || store == NULL || config->serviceURL == NULL ||
      config->username == NULL || config->password == NULL ||
      config->certificatePath == NULL) {
    RCErrorSet(error, 1, "CardDAV mirror configuration is incomplete");
    return 0;
  }
  memset(&httpConfig, 0, sizeof(httpConfig));
  httpConfig.username = config->username;
  httpConfig.password = config->password;
  httpConfig.certificatePath = config->certificatePath;
  httpConfig.allowedHostSuffix = config->allowedHostSuffix;
  httpConfig.userAgent = "RetroCloudSync-CardDAV/0.1";
  client = RCHTTPClientCreate(&httpConfig, error);
  if (client == NULL || !RCContactStoreBeginRun(store, &runIdentifier, error))
    goto finished;
  runStarted = 1;
  RCProgress(config, "Discovering CardDAV principal");
  if (!RCDiscoverHref(client, config->serviceURL, kPrincipalRequest,
      "current-user-principal", kDAVNamespace, &principalURL, error))
    goto finished;
  RCProgress(config, "Discovering address-book home");
  if (!RCDiscoverHref(client, principalURL, kHomeRequest,
      "addressbook-home-set", kCardDAVNamespace, &homeURL, error))
    goto finished;
  RCProgress(config, "Discovering address books");
  if (!RCListCollections(client, homeURL, &collections, &collectionCount,
                         error)) goto finished;
  result->collectionCount = (long)collectionCount;
  for (index = 0; index < collectionCount; index++) {
    if (!RCFetchCollection(config, client, store, &collections[index],
                           runIdentifier, result, error)) goto finished;
  }
  success = 1;

finished:
  if (runStarted) {
    RCErrorClear(&finishError);
    if (!RCContactStoreFinishRun(store, runIdentifier, success,
        success ? NULL : error->message,
        &finishError) && success) {
      if (error != NULL) *error = finishError;
      success = 0;
    }
  }
  RCFreeCollections(collections, collectionCount);
  free(principalURL);
  free(homeURL);
  RCHTTPClientDestroy(client);
  return success;
}
