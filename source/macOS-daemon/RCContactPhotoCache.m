#import "RCAutorelease.h"
#import "RCContactPhoto.h"
#import "RCLogger.h"

NSString *RCContactPhotoURI(RCVCardDocument *document)
{
  RCVCardProperty *photo=NULL; size_t i;
  for(i=0;i<document->propertyCount;i++) if (!strcasecmp(document->properties[i].name,"PHOTO")) {
    if (photo) return nil;
    photo=&document->properties[i];
  }
  if (!photo || !photo->valueType || strcasecmp(photo->valueType,"uri")) return nil;
  return [NSString stringWithUTF8String:photo->originalValue];
}
static BOOL Initialize(RCWriteJournal *j, RCError *error)
{
  if (sqlite3_exec(j->db,"CREATE TABLE IF NOT EXISTS contact_photo_versions("
      "account_id INTEGER NOT NULL,href TEXT NOT NULL,etag TEXT NOT NULL,uri TEXT NOT NULL,"
      "image BLOB NOT NULL,PRIMARY KEY(account_id,href,etag,uri))",NULL,NULL,NULL)==SQLITE_OK) return YES;
  RCErrorSet(error,1,"Could not initialize contact photo cache"); return NO;
}
static void Bind(sqlite3_stmt *q, RCWriteJournal *j, NSString *href, NSString *etag, NSString *uri)
{
  sqlite3_bind_int64(q,1,j->account);
  sqlite3_bind_text(q,2,[href UTF8String],-1,SQLITE_TRANSIENT);
  sqlite3_bind_text(q,3,[etag UTF8String],-1,SQLITE_TRANSIENT);
  sqlite3_bind_text(q,4,[uri UTF8String],-1,SQLITE_TRANSIENT);
}
static NSData *Read(RCWriteJournal *j, NSString *href, NSString *etag, NSString *uri)
{
  sqlite3_stmt *q=NULL; NSData *image=nil;
  if (sqlite3_prepare_v2(j->db,"SELECT image FROM contact_photo_versions WHERE account_id=? AND href=? AND etag=? AND uri=?",-1,&q,NULL)==SQLITE_OK) {
    Bind(q,j,href,etag,uri);
    if (sqlite3_step(q)==SQLITE_ROW) image=[NSData dataWithBytes:sqlite3_column_blob(q,0) length:sqlite3_column_bytes(q,0)];
  }
  sqlite3_finalize(q); return image;
}
BOOL RCContactPhotoRead(RCContactStore *store, RCVCardDocument *document,
    NSString *href, NSString *etag, NSData **image, RCError *error)
{
  *image=RCContactPhoto(document);
  NSString *uri=RCContactPhotoURI(document);
  if (*image || !uri || !store) return YES;
  RCWriteJournal j=RCContactStoreWriteJournal(store);
  *image=Read(&j,href,etag,uri);
  if ([*image length]) return YES;
  RCErrorSet(error,1,"URI contact photo is not cached for this resource version; download required"); return NO;
}
BOOL RCContactPhotoFetch(RCContactStore *store, RCHTTPClient *http, NSString *href,
    NSString *etag, NSData *body, RCError *error)
{
  RCVCardDocument doc;
  if (!RCVCardParse([body bytes],[body length],&doc,error)) { RCVCardDocumentClear(&doc); return NO; }
  NSString *uri=RCContactPhotoURI(&doc); RCVCardDocumentClear(&doc);
  if (!uri) return YES;
  RCWriteJournal j=RCContactStoreWriteJournal(store);
  if (!Initialize(&j,error)) return NO;
  if (Read(&j,href,etag,uri)) return YES;
  NSURL *url=[NSURL URLWithString:uri];
  if (!url || ![[[url scheme] lowercaseString] isEqual:@"https"] || ![[url host] length] ||
      [url user] || [url password] || [url fragment] || ([url port] && [[url port] intValue]!=443) ||
      ![href length] || ![etag length]) {
    RCErrorSet(error,1,"Contact photo requires an absolute HTTPS URL and a versioned resource"); return NO;
  }
  /* The supplied client enforces the account's allowed host suffix on EVERY
     redirect, TLS validation and response limits. Never log the photo URL. */
  RCHTTPResponse photo, owner; RCHTTPResponseInit(&photo); RCHTTPResponseInit(&owner);
  BOOL ok=NO;
  if (!RCHTTPClientRequest(http,"GET",[uri UTF8String],NULL,NULL,NULL,0,&photo,error)) goto done;
  if (photo.statusCode!=200 || !photo.bodyLength || photo.bodyLength>16U*1024U*1024U ||
      !photo.contentType || strncasecmp(photo.contentType,"image/",6)) {
    RCErrorSet(error,1,"Contact photo GET did not return a usable image (HTTP %ld)",photo.statusCode); goto done;
  }
  /* A URI may be reused for another image. Confirm the owning card's ETag
     after fetching bytes before pinning them to its immutable cache entry. */
  if (!RCHTTPClientRequest(http,"GET",[href UTF8String],NULL,NULL,NULL,0,&owner,error)) goto done;
  if (owner.statusCode!=200 || !owner.effectiveURL || strcmp(owner.effectiveURL,[href UTF8String]) ||
      !owner.etag || strcmp(owner.etag,[etag UTF8String]) || owner.bodyLength!=[body length] ||
      memcmp(owner.body,[body bytes],[body length])) {
    RCErrorSet(error,1,"Contact changed while downloading its photo; retry required"); goto done;
  }
  sqlite3_stmt *q=NULL;
  if (sqlite3_prepare_v2(j.db,"INSERT OR IGNORE INTO contact_photo_versions VALUES(?,?,?,?,?)",-1,&q,NULL)==SQLITE_OK) {
    Bind(q,&j,href,etag,uri); sqlite3_bind_blob(q,5,photo.body,(int)photo.bodyLength,SQLITE_TRANSIENT);
    ok=sqlite3_step(q)==SQLITE_DONE;
  }
  sqlite3_finalize(q);
  if (!ok) RCErrorSet(error,1,"Could not save verified contact photo");
done:
  RCHTTPResponseClear(&photo); RCHTTPResponseClear(&owner); return ok;
}
BOOL RCContactPhotoRefresh(RCContactStore *store, RCHTTPClient *http, RCError *error)
{
  RCWriteJournal j=RCContactStoreWriteJournal(store);
  if (!Initialize(&j,error)) return NO;
  NSMutableArray *resources=[NSMutableArray array]; sqlite3_stmt *q=NULL; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j.db,"SELECT c.href,c.usable_etag,c.usable_vcard FROM contacts c JOIN collections b ON b.id=c.collection_id "
      "WHERE b.account_id=? AND b.remote_missing=0 AND c.remote_missing=0 AND c.usable_vcard IS NOT NULL",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j.account);
    while ((step=sqlite3_step(q))==SQLITE_ROW) {
      if (sqlite3_column_type(q,1)==SQLITE_NULL) continue;
      [resources addObject:[NSArray arrayWithObjects:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)],
          [NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,1)],
          [NSData dataWithBytes:sqlite3_column_blob(q,2) length:sqlite3_column_bytes(q,2)],nil]];
    }
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read contact photo resources"); return NO; }
  NSEnumerator *it=[resources objectEnumerator]; NSArray *resource;
  while ((resource=[it nextObject])) {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    @try {
      if (RCCheckCancellation(error) || !RCContactPhotoFetch(store,http,[resource objectAtIndex:0],
          [resource objectAtIndex:1],[resource objectAtIndex:2],error)) return NO;
    } @catch(id exception) {
      RCDrainPoolPreservingException(&pool,exception); @throw;
    } @finally { [pool release]; }
  }
  return YES;
}

/* Pin successful upload images as early as possible, before a later remote
   revision can reuse the same URI. Failure never acknowledges the upload. */
BOOL RCContactPhotoRefreshWrites(RCContactStore *store, RCHTTPClient *http, RCError *error)
{
  RCWriteJournal j=RCContactStoreWriteJournal(store);
  if (!Initialize(&j,error)) return NO;
  NSMutableArray *resources=[NSMutableArray array]; sqlite3_stmt *q=NULL; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j.db,"SELECT href,result_etag,result_body FROM write_operations WHERE account_id=? "
      "AND state='applied' AND kind<>'delete' AND result_etag IS NOT NULL AND result_body IS NOT NULL",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j.account);
    while ((step=sqlite3_step(q))==SQLITE_ROW) [resources addObject:[NSArray arrayWithObjects:
        [NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)],
        [NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,1)],
        [NSData dataWithBytes:sqlite3_column_blob(q,2) length:sqlite3_column_bytes(q,2)],nil]];
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read uploaded contact photo versions"); return NO; }
  BOOL ok=YES; NSEnumerator *it=[resources objectEnumerator]; NSArray *resource;
  while ((resource=[it nextObject])) {
    NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
    @try {
      if(RCCheckCancellation(error)) return NO;
      RCError local; RCErrorClear(&local);
      if (!RCContactPhotoFetch(store,http,[resource objectAtIndex:0],[resource objectAtIndex:1],[resource objectAtIndex:2],&local)) {
        ok=NO; if (error) *error=local;
      }
    } @catch(id exception) {
      RCDrainPoolPreservingException(&resourcePool,exception); @throw;
    } @finally { [resourcePool release]; }
  }
  return ok;
}
