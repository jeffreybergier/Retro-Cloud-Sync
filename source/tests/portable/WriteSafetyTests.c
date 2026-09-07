#define _DEFAULT_SOURCE 1
#include "RCDAVWriter.h"
#include "RCResourcePatch.h"
#include "RCContactStore.h"
#include "RCCalendarStore.h"
#include "RCConflictRecovery.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>

static RCError error;
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s (%s)\n",__LINE__,#x,error.message); exit(1); } } while(0)
static const char *href="https://example.test/book/item.vcf";
static const char baseCard[]="BEGIN:VCARD\r\nVERSION:3.0\r\nUID:stable\r\nN:Name;Old;;;\r\nFN:Old Name\r\nNOTE:old\r\nEND:VCARD\r\n";
static const char newCard[]="BEGIN:VCARD\r\nVERSION:3.0\r\nUID:stable\r\nN:Name;Old;;;\r\nFN:Old Name\r\nNOTE:new\r\nEND:VCARD\r\n";
static char serverFile[100], serverBody[8192], serverETag[128];
static int exists, writes, reads, fault;
enum { Normal, CrashAfterWrite, LoseResponse, PreconditionRace, Normalize,
       ConcurrentAfterWrite, ReadError, RedirectWrite, CanonicalMove };

static void serverSave(void)
{
  FILE *f=fopen(serverFile,"wb"); CHECK(f);
  CHECK(fprintf(f,"%d\n%s\n%s",exists,serverETag,serverBody)>0);
  CHECK(fclose(f)==0);
}
static void serverLoad(void)
{
  FILE *f=fopen(serverFile,"rb"); char line[128]; size_t n;
  CHECK(f && fgets(line,sizeof(line),f)); exists=atoi(line);
  CHECK(fgets(serverETag,sizeof(serverETag),f)); serverETag[strcspn(serverETag,"\n")]=0;
  n=fread(serverBody,1,sizeof(serverBody)-1,f); serverBody[n]=0; fclose(f);
}
static void resetServer(int present, const char *body, const char *etag)
{
  exists=present; snprintf(serverBody,sizeof(serverBody),"%s",body);
  snprintf(serverETag,sizeof(serverETag),"%s",etag); writes=reads=0; fault=Normal; serverSave();
}
void RCHTTPResponseInit(RCHTTPResponse *r) { memset(r,0,sizeof(*r)); }
void RCHTTPResponseClear(RCHTTPResponse *r)
{
  free(r->effectiveURL); free(r->body); free(r->etag); free(r->location); free(r->contentType);
  memset(r,0,sizeof(*r));
}
int RCHTTPClientRequest(RCHTTPClient *c, const char *method, const char *url,
    const char *depth, const char *type, const void *body, size_t length,
    RCHTTPResponse *r, RCError *e)
{
  (void)c; (void)depth; (void)type; (void)body; (void)length;
  CHECK(!strcmp(method,"GET")); reads++;
  if (fault==ReadError) { RCErrorSet(e,1,"simulated read failure"); return 0; }
  RCHTTPResponseClear(r); r->effectiveURL=strdup(fault==CanonicalMove ? "https://example.test/moved" : url);
  r->statusCode=exists ? 200 : 404;
  if (exists) {
    r->etag=strdup(serverETag); r->body=(unsigned char *)strdup(serverBody); r->bodyLength=strlen(serverBody);
  }
  return 1;
}
int RCHTTPClientConditionalRequest(RCHTTPClient *c, const char *method,
    const char *url, const char *type, const void *body, size_t length,
    const char *match, int none, RCHTTPResponse *r, RCError *e)
{
  (void)c; (void)type;
  writes++; RCHTTPResponseClear(r); r->effectiveURL=strdup(url);
  CHECK((match && RCWriteETagIsStrong(match) && !none) || (!match && none));
  if (fault==RedirectWrite) { r->statusCode=307; return 1; }
  if (fault==PreconditionRace) { strcpy(serverETag,"\"concurrent\""); strcpy(serverBody,"concurrent private body"); }
  if ((none && exists) || (match && (!exists || strcmp(match,serverETag)))) {
    r->statusCode=412; return 1;
  }
  if (!strcmp(method,"DELETE")) { exists=0; serverBody[0]=0; r->statusCode=204; }
  else {
    CHECK(!strcmp(method,"PUT") && length<sizeof(serverBody));
    exists=1; memcpy(serverBody,body,length); serverBody[length]=0;
    if (fault==Normalize) strcat(serverBody,"\r\n");
    strcpy(serverETag,"\"written\""); r->statusCode=201; r->etag=strdup(serverETag);
  }
  serverSave();
  if (fault==CrashAfterWrite) _exit(77);
  if (fault==LoseResponse) { RCErrorSet(e,1,"simulated lost response"); return 0; }
  if (fault==ConcurrentAfterWrite) { strcpy(serverBody,"new concurrent body"); strcpy(serverETag,"\"third\""); }
  return 1;
}
static void sql(sqlite3 *db, const char *s) { CHECK(sqlite3_exec(db,s,NULL,NULL,NULL)==SQLITE_OK); }
static long long scalar(sqlite3 *db, const char *s)
{
  sqlite3_stmt *q=NULL; long long v;
  CHECK(sqlite3_prepare_v2(db,s,-1,&q,NULL)==SQLITE_OK && sqlite3_step(q)==SQLITE_ROW);
  v=sqlite3_column_int64(q,0); sqlite3_finalize(q); return v;
}
static RCWriteJournal openJournal(const char *path)
{
  RCWriteJournal j;
  CHECK(sqlite3_open(path,&j.db)==SQLITE_OK); j.account=1;
  sql(j.db,"PRAGMA foreign_keys=ON;CREATE TABLE IF NOT EXISTS accounts(id INTEGER PRIMARY KEY);"
      "INSERT OR IGNORE INTO accounts VALUES(1);INSERT OR IGNORE INTO accounts VALUES(2)");
  CHECK(RCWriteJournalInitialize(j.db,&error)); return j;
}
static void state(RCWriteJournal *j, long long id, const char *wanted)
{
  RCWriteOperation o;
  CHECK(RCWriteJournalGet(j,id,&o,&error)); CHECK(!strcmp(o.state,wanted)); RCWriteOperationClear(&o);
}
static long long enqueue(RCWriteJournal *j, const char *change, const char *key, const char *kind)
{
  long long id;
  CHECK(RCWriteJournalEnqueue(j,change,key,href,kind,!strcmp(kind,"create")?0:1,
      !strcmp(kind,"delete")?NULL:newCard,!strcmp(kind,"delete")?0:strlen(newCard),&id,&error)); return id;
}
static void base(RCWriteJournal *j, const char *key)
{
  CHECK(RCWriteJournalSetBase(j,key,href,"\"base\"",baseCard,strlen(baseCard),1,&error));
}
static void crashTests(const char *path)
{
  int k;
  const char *kinds[]={"create","update","delete"};
  for(k=0;k<3;k++) {
    RCWriteJournal j=openJournal(path); long long id,next; int status; pid_t child;
    sql(j.db,"DELETE FROM write_operations;DELETE FROM write_bases");
    if (k) base(&j,"key");
    id=enqueue(&j,"crash","key",kinds[k]);
    CHECK(!RCWriteJournalAcknowledge(&j,id,&error));
    resetServer(k!=0,baseCard,"\"base\"");
    CHECK(sqlite3_close(j.db)==SQLITE_OK);
    child=fork(); CHECK(child>=0);
    if (!child) {
      j=openJournal(path); fault=CrashAfterWrite;
      RCDAVWriterAttempt(&j,id,NULL,"text/vcard",100,&error); _exit(99);
    }
    CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==77);
    serverLoad(); j=openJournal(path); state(&j,id,"uncertain");
    CHECK(!RCWriteJournalCancel(&j,id,&error));
    CHECK(RCWriteJournalNext(&j,101,&next,&error) && next==0);
    CHECK(RCWriteJournalNext(&j,1000,&next,&error) && next==id);
    CHECK(RCDAVWriterAttempt(&j,id,NULL,"text/vcard",1000,&error));
    state(&j,id,"applied"); CHECK(writes==0); /* Recovery only reads. */
    CHECK(sqlite3_close(j.db)==SQLITE_OK); j=openJournal(path); state(&j,id,"applied");
    sql(j.db,"BEGIN IMMEDIATE"); CHECK(RCWriteJournalAcknowledge(&j,id,&error));
    sql(j.db,"ROLLBACK"); state(&j,id,"applied");
    sql(j.db,"BEGIN IMMEDIATE"); CHECK(RCWriteJournalAcknowledge(&j,id,&error));
    sql(j.db,"COMMIT"); state(&j,id,"acknowledged");
    CHECK(enqueue(&j,"crash","key",kinds[k])==id); /* No duplicate operation. */
    CHECK(sqlite3_close(j.db)==SQLITE_OK);
  }
}
static void recoveryTests(const char *path)
{
  RCWriteJournal j=openJournal(path); RCWriteOperation o;
  long long id,other,next; int scenarios[]={Normal,LoseResponse,PreconditionRace,Normalize,ConcurrentAfterWrite,ReadError,RedirectWrite,CanonicalMove};
  size_t i;
  for (i=0;i<sizeof(scenarios)/sizeof(scenarios[0]);i++) {
    sql(j.db,"DELETE FROM write_operations;DELETE FROM write_bases"); base(&j,"key");
    id=enqueue(&j,"change","key","update");
    CHECK(!RCWriteJournalEnqueue(&j,"other","key",href,"update",1,newCard,strlen(newCard),&other,&error));
    CHECK(!RCWriteJournalEnqueue(&j,"change","key",href,"update",1,baseCard,strlen(baseCard),&other,&error));
    CHECK(RCWriteJournalSetBase(&j,"key",href,"\"later\"",newCard,strlen(newCard),2,&error));
    CHECK(RCWriteJournalGet(&j,id,&o,&error)); CHECK(!strcmp(o.baseETag,"\"base\"") && !memcmp(o.baseBody,baseCard,o.baseLength)); RCWriteOperationClear(&o);
    j.account=2; CHECK(!RCWriteJournalGet(&j,id,&o,&error));
    CHECK(!RCWriteJournalAcknowledge(&j,id,&error)); CHECK(!RCWriteJournalBeginAttempt(&j,id,100,&error));
    base(&j,"key"); other=enqueue(&j,"change","key","update"); CHECK(other!=id); j.account=1;
    resetServer(1,baseCard,"\"base\""); fault=scenarios[i];
    sql(j.db,"BEGIN IMMEDIATE"); CHECK(!RCDAVWriterAttempt(&j,id,NULL,"text/vcard",100,&error)); CHECK(!writes && !reads); sql(j.db,"ROLLBACK");
    if (fault==LoseResponse || fault==ReadError || fault==CanonicalMove)
      CHECK(!RCDAVWriterAttempt(&j,id,NULL,"text/vcard",100,&error));
    else CHECK(RCDAVWriterAttempt(&j,id,NULL,"text/vcard",100,&error));
    if (fault==Normal || fault==Normalize) state(&j,id,"applied");
    else if (fault==PreconditionRace || fault==ConcurrentAfterWrite) {
      state(&j,id,"conflict"); CHECK(!RCWriteJournalAcknowledge(&j,id,&error));
      CHECK(RCWriteJournalGet(&j,id,&o,&error)); CHECK(o.resultBody && !strcmp(o.baseETag,"\"base\"")); RCWriteOperationClear(&o);
      CHECK(RCWriteJournalNext(&j,1000,&next,&error) && !next);
      CHECK(RCWriteJournalCancel(&j,id,&error));
    } else {
      state(&j,id,"uncertain"); fault=Normal; writes=0;
      CHECK(RCDAVWriterAttempt(&j,id,NULL,"text/vcard",1000,&error)); state(&j,id,"applied");
      CHECK(writes==(scenarios[i]==LoseResponse ? 0 : 1));
    }
  }
  sql(j.db,"DELETE FROM write_operations;DELETE FROM write_bases"); base(&j,"key");
  id=enqueue(&j,"edit","key","update"); resetServer(1,"other device edit","\"other\"");
  CHECK(RCDAVWriterAttempt(&j,id,NULL,"text/vcard",100,&error)); state(&j,id,"conflict"); CHECK(writes==0);
  CHECK(!RCWriteETagIsStrong("W/\"weak\"") && !RCWriteETagIsStrong("\"bad\r\nheader\""));
  CHECK(RCWriteJournalSetBase(&j,"weak",href,"W/\"weak\"",baseCard,strlen(baseCard),1,&error));
  CHECK(!RCWriteJournalEnqueue(&j,"weak","weak",href,"delete",1,NULL,0,&other,&error));
  sql(j.db,"DELETE FROM write_operations;DELETE FROM write_bases");
  id=enqueue(&j,"create collision","key","create"); resetServer(1,baseCard,"\"occupied\"");
  CHECK(RCDAVWriterAttempt(&j,id,NULL,"text/vcard",100,&error)); state(&j,id,"conflict"); CHECK(!writes);
  CHECK(RCWriteJournalCancel(&j,id,&error)); base(&j,"key");
  id=enqueue(&j,"remote deleted","key","update"); resetServer(0,"","");
  CHECK(RCDAVWriterAttempt(&j,id,NULL,"text/vcard",100,&error)); state(&j,id,"conflict"); CHECK(!writes);
  CHECK(RCWriteJournalCancel(&j,id,&error));
  id=enqueue(&j,"delete conflict","key","delete"); resetServer(1,newCard,"\"remote edit\"");
  CHECK(RCDAVWriterAttempt(&j,id,NULL,"text/vcard",100,&error)); state(&j,id,"conflict"); CHECK(!writes);
  CHECK(sqlite3_close(j.db)==SQLITE_OK);
}
static void patchTests(const char *path)
{
  const char *card="BEGIN:VCARD\r\nVERSION:3.0\r\nUID:keep\r\nN:Name;Old;;;\r\nFN:Old Name\r\n"
      "item1.TEL;TYPE=CELL;X-PRIVATE=\"a:b\":111\r\nitem1.X-ABLabel:custom\r\n"
      "TEL:222\r\nTEL:333\r\nPHOTO;ENCODING=b;TYPE=JPEG:YWJj\r\n ZGVm\r\n"
      "X-APPLE-UNKNOWN;X-PARAM=keep:private\r\nEND:VCARD\r\n";
  const char *calendar="BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\n"
      "BEGIN:VTIMEZONE\r\nTZID:Custom\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\n"
      "TZOFFSETFROM:+0100\r\nTZOFFSETTO:+0100\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n"
      "BEGIN:VEVENT\r\nUID:event\r\nDTSTART:20260906T100000Z\r\nRRULE:FREQ=DAILY;COUNT=5\r\n"
      "SUMMARY;LANGUAGE=en;X-PRIVATE=stay:Master\r\nX-APPLE-TRAVEL:keep\r\n"
      "BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nDESCRIPTION:alarm\r\nEND:VALARM\r\nEND:VEVENT\r\n"
      "BEGIN:VEVENT\r\nUID:event\r\nRECURRENCE-ID:20260907T100000Z\r\nDTSTART:20260907T120000Z\r\nSUMMARY:Exception\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
  RCResourceEdit ce[]={{0,"TEL","item1",0,"999",NULL},{0,"TEL",NULL,0,NULL,NULL},{0,"TEL",NULL,1,NULL,NULL},{0,"NOTE",NULL,-1,"new\\nline",NULL}};
  RCResourceEdit ie[]={{3,"SUMMARY",NULL,0,"Changed master",NULL},{5,"SUMMARY",NULL,0,"Changed exception",NULL}};
  RCResourceEdit bad={0,"UID",NULL,0,"changed",NULL};
  unsigned char *out=NULL; size_t n; RCWriteJournal j=openJournal(path); long long id,again;
  CHECK(RCResourcePatch(RCResourceVCard,(const unsigned char *)card,strlen(card),ce,4,&out,&n,&error));
  CHECK(strstr((char *)out,"item1.TEL;TYPE=CELL;X-PRIVATE=\"a:b\":999\r\n"));
  CHECK(strstr((char *)out,"PHOTO;ENCODING=b;TYPE=JPEG:YWJj\r\n ZGVm\r\n"));
  CHECK(strstr((char *)out,"item1.X-ABLabel:custom\r\n") && strstr((char *)out,"X-APPLE-UNKNOWN;X-PARAM=keep:private\r\n"));
  CHECK(!strstr((char *)out,"TEL:222") && !strstr((char *)out,"TEL:333") && strstr((char *)out,"NOTE:new\\nline\r\n")); free(out);
  CHECK(!RCResourcePatch(RCResourceVCard,(const unsigned char *)card,strlen(card),&bad,1,&out,&n,&error));
  {
    RCResourceEdit append={0,"EMAIL","new-entry",-1,"new@example.test","TYPE=HOME,PREF"};
    CHECK(RCResourcePatch(RCResourceVCard,(const unsigned char *)card,strlen(card),&append,1,&out,&n,&error));
    CHECK(strstr((char *)out,"new-entry.EMAIL;TYPE=HOME,PREF:new@example.test\r\n")); free(out);
    append.parameters="TYPE=HOME\r\nUID:injected";
    CHECK(!RCResourcePatch(RCResourceVCard,(const unsigned char *)card,strlen(card),&append,1,&out,&n,&error));
    append.parameters="TYPE=WORK"; append.property="TEL"; append.group="item1"; append.occurrence=0;
    CHECK(!RCResourcePatch(RCResourceVCard,(const unsigned char *)card,strlen(card),&append,1,&out,&n,&error));
  }
  ce[1]=ce[0]; CHECK(!RCResourcePatch(RCResourceVCard,(const unsigned char *)card,strlen(card),ce,2,&out,&n,&error));
  ce[0].value="bad\r\nUID:injected"; CHECK(!RCResourcePatch(RCResourceVCard,(const unsigned char *)card,strlen(card),ce,1,&out,&n,&error));
  CHECK(RCResourcePatch(RCResourceCalendar,(const unsigned char *)calendar,strlen(calendar),ie,2,&out,&n,&error));
  CHECK(strstr((char *)out,"SUMMARY;LANGUAGE=en;X-PRIVATE=stay:Changed master\r\n"));
  CHECK(strstr((char *)out,"RECURRENCE-ID:20260907T100000Z\r\nDTSTART:20260907T120000Z\r\nSUMMARY:Changed exception"));
  CHECK(strstr((char *)out,"RRULE:FREQ=DAILY;COUNT=5\r\n") && strstr((char *)out,"TRIGGER:-PT15M\r\n") && strstr((char *)out,"TZOFFSETTO:+0100\r\n")); free(out);
  CHECK(RCResourcePatch(RCResourceCalendar,(const unsigned char *)calendar,strlen(calendar),NULL,0,&out,&n,&error));
  CHECK(n==strlen(calendar) && !memcmp(out,calendar,n)); free(out);
  {
    char longValue[601]; size_t index; RCVCardDocument document;
    RCResourceEdit edit={0,"NOTE",NULL,-1,longValue,NULL};
    for(index=0;index<sizeof(longValue)-1;index+=2) { longValue[index]=(char)0xc3; longValue[index+1]=(char)0xa9; }
    longValue[sizeof(longValue)-1]=0;
    CHECK(RCResourcePatch(RCResourceVCard,(const unsigned char *)card,strlen(card),&edit,1,&out,&n,&error));
    CHECK(RCVCardParse(out,n,&document,&error));
    for(index=0;index<document.propertyCount;index++) if (!strcmp(document.properties[index].name,"NOTE")) break;
    CHECK(index<document.propertyCount && !strcmp(document.properties[index].decodedValue,longValue));
    RCVCardDocumentClear(&document); free(out);
  }
  sql(j.db,"DELETE FROM write_operations;DELETE FROM write_bases"); base(&j,"key");
  bad.property="NOTE"; bad.value="new";
  CHECK(RCResourceEnqueueEdits(&j,"patch","key",1,RCResourceVCard,&bad,1,&id,&error));
  CHECK(RCWriteJournalSetBase(&j,"key",href,"\"newbase\"",newCard,strlen(newCard),2,&error));
  CHECK(RCResourceEnqueueEdits(&j,"patch","key",1,RCResourceVCard,&bad,1,&again,&error) && again==id);
  bad.value="different"; CHECK(!RCResourceEnqueueEdits(&j,"patch","key",1,RCResourceVCard,&bad,1,&again,&error));
  CHECK(sqlite3_close(j.db)==SQLITE_OK);
}
static void storeTests(const char *contactPath, const char *calendarPath)
{
  RCContactStore *s=RCContactStoreOpen(contactPath,"account",&error);
  RCWriteJournal j; long long run,collection,generation,published,id; int invalid;
  CHECK(s); j=RCContactStoreWriteJournal(s);
  CHECK(RCContactStoreBeginRun(s,&run,&error));
  CHECK(RCContactStoreGetCollection(s,"https://example.test/book/","Book",&collection,&error));
  CHECK(RCContactStoreSaveResource(s,collection,run,href,"\"original\"",(const unsigned char *)baseCard,strlen(baseCard),&invalid,&error));
  CHECK(RCContactStoreFinishCollection(s,collection,run,&error) && RCContactStoreFinishRun(s,run,1,NULL,&error));
  CHECK(scalar(j.db,"SELECT count(*) FROM write_bases")==0);
  CHECK(RCContactStoreGetPublicationState(s,&generation,&published,&error));
  CHECK(RCContactStoreMarkPublished(s,generation,&error));
  CHECK(scalar(j.db,"SELECT count(*) FROM write_bases WHERE etag='\"original\"'")==1);
  CHECK(RCContactStoreBeginRun(s,&run,&error));
  CHECK(RCContactStoreGetCollection(s,"https://example.test/book/","Book",&collection,&error));
  CHECK(RCContactStoreSaveResource(s,collection,run,href,"\"malformed\"",(const unsigned char *)"bad",3,&invalid,&error) && invalid);
  CHECK(RCContactStoreFinishCollection(s,collection,run,&error) && RCContactStoreFinishRun(s,run,1,NULL,&error));
  CHECK(RCContactStoreGetPublicationState(s,&generation,&published,&error));
  CHECK(RCContactStoreMarkPublished(s,generation,&error));
  CHECK(scalar(j.db,"SELECT count(*) FROM write_bases WHERE etag='\"original\"'")==1);
  CHECK(!RCContactStoreMarkPublished(s,generation+1,&error));
  CHECK(scalar(j.db,"SELECT count(*) FROM write_bases WHERE etag='\"original\"'")==1);
  RCContactStoreClose(s);
  {
    RCCalendarStore *c=RCCalendarStoreOpen(calendarPath,"account",&error); RCDAVCollection col;
    const char *ics="BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART:20260906T100000Z\r\nSUMMARY:Event\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    CHECK(c); j=RCCalendarStoreWriteJournal(c); memset(&col,0,sizeof(col)); col.url="https://example.test/cal/"; col.displayName="Cal";
    CHECK(RCCalendarStoreBeginRun(c,&error) && RCCalendarStoreCollection(c,&col,&id,&error));
    CHECK(RCCalendarStoreSave(c,id,"https://example.test/cal/event.ics","\"exported\"",(const unsigned char *)ics,strlen(ics),&error));
    CHECK(RCCalendarStoreFinishRun(c,1,NULL,&error));
    generation=scalar(c->db,"SELECT generation FROM accounts");
    CHECK(!RCCalendarStoreSnapshotWriteBases(c,generation,&error));
    sql(c->db,"BEGIN IMMEDIATE;UPDATE calendar_resources SET export_ical=raw_ical,export_etag=etag");
    CHECK(RCCalendarStoreSnapshotWriteBases(c,generation,&error)); sql(c->db,"COMMIT");
    CHECK(scalar(c->db,"SELECT count(*) FROM write_bases WHERE etag='\"exported\"'")==1);
    sql(c->db,"UPDATE calendar_resources SET etag='\"unsupported replacement\"';BEGIN IMMEDIATE");
    CHECK(RCCalendarStoreSnapshotWriteBases(c,generation,&error)); sql(c->db,"COMMIT");
    CHECK(scalar(c->db,"SELECT count(*) FROM write_bases WHERE etag='\"exported\"'")==1);
    RCCalendarStoreClose(c);
  }
}
typedef struct {
  RCWriteJournal *journal;
  int disposition, crash, newerLocal;
  const char *resolved;
  char acceptancePath[200];
} RecoveryContext;
static int resolveConflict(void *opaque, const RCWriteOperation *o,
    RCConflictDecision *d, RCError *e)
{
  RecoveryContext *c=opaque;
  (void)e;
  CHECK(sqlite3_get_autocommit(c->journal->db));
  CHECK(o->baseBody && o->desiredBody && o->resultBody);
  if (c->disposition!=RCConflictResolved) {
    d->attentionReason="unsupported-mapping"; return c->disposition;
  }
  d->kind=strdup("update"); d->body=strdup(c->resolved);
  d->length=strlen(c->resolved); d->receipt=strdup("canonical-revision-one");
  d->receiptLength=strlen(d->receipt);
  return RCConflictResolved;
}
static int saveResolution(void *opaque, const RCWriteOperation *o, RCError *e)
{
  RecoveryContext *c=opaque;
  (void)e;
  CHECK(!sqlite3_get_autocommit(c->journal->db));
  CHECK(o->resultBody && !strcmp(o->resultETag,"\"written\""));
  sql(c->journal->db,"INSERT INTO mirror_completions VALUES(1)");
  if (c->crash==1) _exit(78);
  return 1;
}
static int acceptResolution(void *opaque, const RCWriteOperation *o,
    const void *receipt, size_t length, RCError *e)
{
  RecoveryContext *c=opaque;
  FILE *f;
  (void)o;
  CHECK(sqlite3_get_autocommit(c->journal->db));
  CHECK(length==strlen("canonical-revision-one") &&
      !memcmp(receipt,"canonical-revision-one",length));
  if (c->newerLocal) { RCErrorSet(e,1,"Newer local change remains pending"); return 0; }
  /* Model an idempotent framework acknowledgement whose state survives a crash
     independently of SQLite. A duplicate acceptance would append a second line. */
  if (access(c->acceptancePath,F_OK)) {
    f=fopen(c->acceptancePath,"w"); CHECK(f);
    CHECK(fputs("accepted\n",f)>=0 && !fclose(f));
  }
  if (c->crash==2) _exit(79);
  return 1;
}
static void crashResolution(sqlite3_context *context, int argc, sqlite3_value **argv)
{
  (void)context; (void)argc; (void)argv; _exit(80);
}
static void conflictTests(const char *path)
{
  RCWriteJournal j=openJournal(path);
  RCWriteOperation original,replacement;
  RCConflictCallbacks callbacks;
  RecoveryContext c;
  long long id,next,again;
  void *receipt=NULL; size_t length; int mirrored,phase,status;
  pid_t child;
  memset(&c,0,sizeof(c)); c.journal=&j; c.resolved=newCard;
  c.disposition=RCConflictResolved;
  snprintf(c.acceptancePath,sizeof(c.acceptancePath),"%s-acceptance",path);
  callbacks.context=&c; callbacks.resolve=resolveConflict;
  callbacks.saveMirror=saveResolution; callbacks.acceptLocal=acceptResolution;
  sql(j.db,"DELETE FROM write_operations;DELETE FROM write_bases;"
      "CREATE TABLE mirror_completions(id INTEGER PRIMARY KEY)");
  base(&j,"key"); id=enqueue(&j,"reconcile","key","update");
  resetServer(1,baseCard,"\"remote\"");
  CHECK(RCDAVWriterAttempt(&j,id,NULL,"text/vcard",100,&error)); state(&j,id,"conflict");
  CHECK(RCWriteJournalNextConflict(&j,&next,&error) && next==id);
  c.disposition=RCConflictDeferred;
  CHECK(RCConflictRecover(&j,id,&callbacks,&next,&error) && !next); state(&j,id,"conflict");
  c.disposition=RCConflictNeedsAttention;
  CHECK(RCConflictRecover(&j,id,&callbacks,&next,&error) && !next);
  CHECK(RCWriteJournalNextConflict(&j,&next,&error) && !next);
  CHECK(!RCWriteJournalConflictAttention(&j,id,"private body!",&error));
  CHECK(RCWriteJournalConflictAttention(&j,id,NULL,&error));
  c.disposition=RCConflictResolved;
  /* Terminate after successor insertion but before the resolution link/retiring
     the old conflict. SQLite must retain the entire old state, with no orphan. */
  CHECK(sqlite3_close(j.db)==SQLITE_OK);
  child=fork(); CHECK(child>=0);
  if (!child) {
    j=openJournal(path);
    CHECK(sqlite3_create_function(j.db,"crash_resolution",0,SQLITE_UTF8,NULL,
        crashResolution,NULL,NULL)==SQLITE_OK);
    sql(j.db,"CREATE TEMP TRIGGER interrupt_resolution BEFORE INSERT ON write_resolutions "
        "BEGIN SELECT crash_resolution(); END");
    RCConflictRecover(&j,id,&callbacks,&next,&error); _exit(99);
  }
  CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==80);
  j=openJournal(path);
  state(&j,id,"conflict"); CHECK(scalar(j.db,"SELECT count(*) FROM write_operations")==1);
  j.account=2; CHECK(!RCConflictRecover(&j,id,&callbacks,&next,&error)); j.account=1;
  CHECK(RCConflictRecover(&j,id,&callbacks,&next,&error) && next);
  state(&j,id,"cancelled"); state(&j,next,"queued");
  CHECK(RCWriteJournalGet(&j,id,&original,&error));
  CHECK(RCWriteJournalGet(&j,next,&replacement,&error));
  CHECK(!strcmp(original.baseETag,"\"base\"") && !strcmp(replacement.baseETag,"\"remote\""));
  CHECK(!strcmp((char *)original.desiredBody,newCard));
  RCWriteOperationClear(&original); RCWriteOperationClear(&replacement);
  CHECK(RCWriteJournalResolveConflict(&j,id,"update",newCard,strlen(newCard),
      "canonical-revision-one",strlen("canonical-revision-one"),&again,&error) && again==next);
  CHECK(!RCWriteJournalResolveConflict(&j,id,"update",baseCard,strlen(baseCard),
      "canonical-revision-one",strlen("canonical-revision-one"),&again,&error));
  CHECK(!RCConflictComplete(&j,next,&callbacks,&error));
  /* A second device edit races the resolution. The successor conflicts again,
     and both rounds retain their own immutable bases and local decisions. */
  resetServer(1,baseCard,"\"second-remote\"");
  CHECK(RCDAVWriterAttempt(&j,next,NULL,"text/vcard",200,&error)); state(&j,next,"conflict");
  CHECK(RCConflictRecover(&j,next,&callbacks,&again,&error) && again);
  CHECK(RCDAVWriterAttempt(&j,again,NULL,"text/vcard",300,&error)); state(&j,again,"applied");
  CHECK(RCWriteJournalRecoveryNext(&j,0,&next,&error) && next==again);
  CHECK(RCWriteJournalRecoveryNext(&j,again,&next,&error) && !next);
  CHECK(!RCWriteJournalAcknowledge(&j,again,&error));
  CHECK(!RCWriteJournalResolutionMirrored(&j,again,&error));
  CHECK(sqlite3_close(j.db)==SQLITE_OK);
  for (phase=1;phase<=2;phase++) {
    child=fork(); CHECK(child>=0);
    if (!child) {
      j=openJournal(path); c.crash=phase;
      RCConflictComplete(&j,again,&callbacks,&error); _exit(99);
    }
    CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==77+phase);
    j=openJournal(path);
    CHECK(RCWriteJournalResolutionReceipt(&j,again,&receipt,&length,&mirrored,&error)); free(receipt);
    CHECK(mirrored==(phase==2));
    CHECK(scalar(j.db,"SELECT count(*) FROM mirror_completions")==phase-1);
    state(&j,again,"applied");
    CHECK(sqlite3_close(j.db)==SQLITE_OK);
  }
  j=openJournal(path); c.crash=0; c.newerLocal=1;
  CHECK(!RCConflictComplete(&j,again,&callbacks,&error)); state(&j,again,"applied");
  CHECK(scalar(j.db,"SELECT count(*) FROM mirror_completions")==1);
  c.newerLocal=0;
  CHECK(RCConflictComplete(&j,again,&callbacks,&error)); state(&j,again,"acknowledged");
  CHECK(RCConflictComplete(&j,again,&callbacks,&error));
  CHECK(scalar(j.db,"SELECT count(*) FROM mirror_completions")==1);
  /* Explicit deletion/collision attention does not prevent another resource's
     ordinary queued operation from being selected by the writer. */
  sql(j.db,"DELETE FROM write_attention;DELETE FROM write_resolutions;DELETE FROM write_operations;DELETE FROM write_bases");
  base(&j,"key"); id=enqueue(&j,"deleted","key","update"); resetServer(0,"","");
  CHECK(RCDAVWriterAttempt(&j,id,NULL,"text/vcard",400,&error));
  CHECK(RCConflictRecover(&j,id,&callbacks,&next,&error) && !next);
  CHECK(RCWriteJournalNextConflict(&j,&next,&error) && !next);
  CHECK(RCWriteJournalEnqueue(&j,"unrelated","other","https://example.test/book/other.vcf",
      "create",0,newCard,strlen(newCard),&next,&error));
  CHECK(RCWriteJournalNext(&j,500,&again,&error) && again==next);
  {
    char snapshot[200]; sqlite3 *copy=NULL; struct stat info;
    snprintf(snapshot,sizeof(snapshot),"%s-recovery",path);
    sql(j.db,"BEGIN IMMEDIATE");
    CHECK(!RCWriteJournalBackup(j.db,snapshot,&error) && access(snapshot,F_OK));
    sql(j.db,"ROLLBACK");
    CHECK(RCWriteJournalBackup(j.db,snapshot,&error));
    CHECK(!stat(snapshot,&info) && (info.st_mode & 0777)==0600);
    CHECK(!RCWriteJournalBackup(j.db,snapshot,&error));
    CHECK(sqlite3_open(snapshot,&copy)==SQLITE_OK);
    CHECK(scalar(copy,"SELECT count(*) FROM write_operations")==2);
    CHECK(scalar(copy,"SELECT count(*) FROM write_attention")==1);
    CHECK(sqlite3_close(copy)==SQLITE_OK); unlink(snapshot);
  }
  CHECK(sqlite3_close(j.db)==SQLITE_OK); unlink(c.acceptancePath);
}
static void nativeReceiptTransactionTests(const char *path)
{
  RCWriteJournal j=openJournal(path);
  long long id;
  sql(j.db,"DELETE FROM write_attention;DELETE FROM write_resolutions;DELETE FROM write_operations;DELETE FROM write_bases;"
      "CREATE TABLE IF NOT EXISTS native_receipts(operation_id INTEGER PRIMARY KEY,receipt TEXT NOT NULL)");
  sql(j.db,"BEGIN IMMEDIATE");
  CHECK(RCWriteJournalEnqueue(&j,"receipt-rollback","native-resource",href,"create",0,newCard,strlen(newCard),&id,&error));
  CHECK(!sqlite3_get_autocommit(j.db));
  sql(j.db,"INSERT INTO native_receipts SELECT id,'exact snapshot' FROM write_operations;ROLLBACK");
  CHECK(scalar(j.db,"SELECT count(*) FROM write_operations")==0);
  CHECK(scalar(j.db,"SELECT count(*) FROM native_receipts")==0);
  sql(j.db,"BEGIN IMMEDIATE");
  CHECK(RCWriteJournalEnqueue(&j,"receipt-commit","native-resource",href,"create",0,newCard,strlen(newCard),&id,&error));
  sql(j.db,"INSERT INTO native_receipts SELECT id,'exact snapshot' FROM write_operations;COMMIT");
  CHECK(scalar(j.db,"SELECT count(*) FROM write_operations JOIN native_receipts ON operation_id=id")==1);
  sql(j.db,"BEGIN IMMEDIATE");
  CHECK(!RCWriteJournalEnqueue(&j,"collision","other",href,"create",0,newCard,strlen(newCard),&id,&error));
  CHECK(!sqlite3_get_autocommit(j.db));
  sql(j.db,"ROLLBACK");
  CHECK(scalar(j.db,"SELECT count(*) FROM write_operations")==1);
  CHECK(sqlite3_close(j.db)==SQLITE_OK);
}
int main(void)
{
  char dir[]="/tmp/retro-write-tests-XXXXXX",db[100],contacts[100],calendars[100];
  CHECK(mkdtemp(dir)); snprintf(db,sizeof(db),"%s/journal.sqlite",dir);
  snprintf(serverFile,sizeof(serverFile),"%s/server",dir);
  snprintf(contacts,sizeof(contacts),"%s/contacts.sqlite",dir); snprintf(calendars,sizeof(calendars),"%s/calendars.sqlite",dir);
  crashTests(db); recoveryTests(db); patchTests(db); storeTests(contacts,calendars); conflictTests(db); nativeReceiptTransactionTests(db);
  unlink(db); unlink(serverFile); unlink(contacts); unlink(calendars); rmdir(dir);
  puts("Write journal, conflict reconciliation/repeated races, completion crash recovery, account isolation and loss-preserving edits passed.");
  return 0;
}
