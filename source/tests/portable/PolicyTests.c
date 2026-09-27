#include "RCPhotoCodec.h"
#include "RCStatusPolicy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)

static void Photos(void)
{
  unsigned char input[256], *decoded;
  const char *invalid[]={"", " \t\r\n", "Zg=", "Zh==", "Zm9=", "=m9v", "Zg==x", "Zg==Zg==", "Zg==!", "!!!!"};
  size_t i,n;
  for (i=0;i<sizeof(input);i++) input[i]=(unsigned char)i;
  for (i=1;i<=sizeof(input);i++) {
    char *encoded=RCPhotoEncodeBytes(input,i); CHECK(encoded);
    decoded=RCPhotoDecodeBytes(encoded,&n); CHECK(decoded && n==i && !memcmp(input,decoded,n));
    free(encoded); free(decoded);
  }
  for (i=0;i<sizeof(invalid)/sizeof(*invalid);i++) {
    CHECK(!RCPhotoDecodeBytes(invalid[i],&n) && n==0);
  }
  decoded=RCPhotoDecodeBytes(" Z m\t9v\r\n",&n); CHECK(decoded && n==3 && !memcmp(decoded,"foo",3)); free(decoded);
  CHECK(!RCPhotoEncodeBytes(input,(size_t)-1));
  CHECK(!strcmp(RCPhotoMediaType((const unsigned char *)"\211PNG\r\n\032\n",8),"PNG"));
  CHECK(!strcmp(RCPhotoMediaType((const unsigned char *)"\377\330\377",3),"JPEG"));
  CHECK(!strcmp(RCPhotoMediaType((const unsigned char *)"GIF89a",6),"GIF"));
  CHECK(!strcmp(RCPhotoMediaType((const unsigned char *)"II\052\000",4),"TIFF"));
  CHECK(!RCPhotoMediaType(input,3));
  {
    RCVCardParameter params[2]; RCVCardProperty props[2]; RCVCardDocument doc;
    memset(&doc,0,sizeof(doc)); memset(props,0,sizeof(props)); memset(params,0,sizeof(params));
    params[0].name="ENCODING"; params[0].value="b";
    props[0].name="PHOTO"; props[0].originalValue="AAH/"; props[0].parameters=params; props[0].parameterCount=1;
    doc.properties=props; doc.propertyCount=1;
    decoded=RCPhotoFromVCard(&doc,&n); CHECK(decoded && n==3 && decoded[2]==255); free(decoded);
    props[1]=props[0]; doc.propertyCount=2; CHECK(!RCPhotoFromVCard(&doc,&n));
    doc.propertyCount=1; params[1].name="VALUE"; params[1].value="uri"; props[0].parameterCount=2;
    CHECK(!RCPhotoFromVCard(&doc,&n));
    props[0].parameterCount=0; CHECK(!RCPhotoFromVCard(&doc,&n));
  }
}
static void SQL(sqlite3 *db,const char *sql) { CHECK(sqlite3_exec(db,sql,NULL,NULL,NULL)==SQLITE_OK); }
static void Status(void)
{
  RCWriteJournal j; RCStatusResult result;
  j.account=1; CHECK(sqlite3_open(":memory:",&j.db)==SQLITE_OK);
  result=RCStatusEvaluate(&j,1,1,0,0); CHECK(result.known && result.advanceSuccess && !strcmp(result.phase,"UpToDate"));
  CHECK(!RCStatusEvaluate(&j,1,0,0,0).advanceSuccess);
  result=RCStatusEvaluate(&j,1,1,1,0); CHECK(!result.advanceSuccess && !strcmp(result.phase,"Error"));
  result=RCStatusEvaluate(&j,1,1,1,1); CHECK(!result.advanceSuccess && !strcmp(result.phase,"Stopping"));
  SQL(j.db,"CREATE TABLE write_operations(account_id INTEGER,state TEXT); INSERT INTO write_operations VALUES(1,'acknowledged'),(1,'cancelled'),(2,'uncertain');");
  CHECK(RCStatusEvaluate(&j,1,1,0,0).advanceSuccess);
  SQL(j.db,"INSERT INTO write_operations VALUES(1,'uncertain');");
  result=RCStatusEvaluate(&j,1,1,0,0); CHECK(result.pending==1 && !result.advanceSuccess && !strcmp(result.phase,"Attention"));
  SQL(j.db,"UPDATE write_operations SET state='acknowledged'; CREATE TABLE calendars(id INTEGER,account_id INTEGER); INSERT INTO calendars VALUES(1,1),(2,2); CREATE TABLE calendar_resources(calendar_id INTEGER,remote_missing INTEGER,scope_excluded INTEGER,parse_error TEXT,export_status TEXT); INSERT INTO calendar_resources VALUES(1,0,1,'bad',NULL),(2,0,0,'bad',NULL),(1,1,0,'bad',NULL);");
  CHECK(RCStatusEvaluate(&j,0,1,0,0).advanceSuccess);
  SQL(j.db,"INSERT INTO calendar_resources VALUES(1,0,0,NULL,'retained previous');");
  result=RCStatusEvaluate(&j,0,1,0,0); CHECK(result.pending==1 && !result.advanceSuccess);
  SQL(j.db,"CREATE TABLE two_way_attention(broken INTEGER);");
  result=RCStatusEvaluate(&j,1,1,0,0); CHECK(!result.known && !result.advanceSuccess);
  sqlite3_close(j.db);
}
int main(void)
{
  Photos(); Status();
  puts("Portable photo codec and account-scoped status policies passed.");
  return 0;
}
