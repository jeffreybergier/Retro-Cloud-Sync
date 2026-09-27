#include "RCSyncPolicy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
typedef struct Value Value;
typedef struct { const char *key; const Value *value; } Pair;
struct Value { int kind; const char *text; int number; size_t count; const Pair *pairs; const Value *const *items; };
enum { String=1, Number, Array, Record, Tombstone };
#define STR(s) {String,s,0,0,NULL,NULL}
#define NUM(n) {Number,NULL,n,0,NULL,NULL}
#define MAP(p) {Record,NULL,0,sizeof(p)/sizeof(*p),p,NULL}
#define LIST(p) {Array,NULL,0,sizeof(p)/sizeof(*p),NULL,p}
static size_t Count(RCRecord r) { return r ? ((const Value *)r)->count : 0; }
typedef struct { const Value *record; size_t index; } Iterator;
/* Test-only arena keeps borrowed iterators alive through recursive comparisons. */
static Iterator iterators[4096]; static size_t used;
static void *Keys(RCRecord r) { CHECK(used<4096); iterators[used].record=r; iterators[used].index=0; return &iterators[used++]; }
static RCRecord Next(void *p) { Iterator *it=p; return it->index<Count(it->record) ? it->record->pairs[it->index++].key : NULL; }
static RCRecord Get(RCRecord r,RCRecord key)
{
  const Value *v=r; size_t i;
  for(i=0;i<Count(r);i++) if(!strcmp(v->pairs[i].key,key)) return v->pairs[i].value;
  return NULL;
}
static const char *Text(RCRecord key) { return key; }
static const char *Entity(RCRecord r) { const Value *v=Get(r,"com.apple.syncservices.RecordEntityName"); return v ? v->text : NULL; }
static int Empty(const Value *v) { return !v || (v->kind==String && !*v->text) || (v->kind==Array && !v->count); }
static int Equal(const Value *a,const Value *b)
{
  size_t i;
  if(!a || !b) return a==b;
  if(a->kind!=b->kind) return 0;
  if(a->kind==String) return !strcmp(a->text,b->text);
  if(a->kind==Number) return a->number==b->number;
  if(a->kind==Array) { if(a->count!=b->count) return 0; for(i=0;i<a->count;i++) if(!Equal(a->items[i],b->items[i])) return 0; return 1; }
  return a==b;
}
static int PropertyEqual(const char *entity,const char *key,RCRecord x,RCRecord y)
{
  const Value *a=x,*b=y; RCFieldDefault def=RCSyncFieldDefault(entity,key);
  Value d={def.text ? String : Number,def.text,def.number,0,NULL,NULL};
  if(def.present) { if(Empty(a)) a=&d; if(Empty(b)) b=&d; }
  return (Empty(a) && Empty(b)) || Equal(a,b);
}
static int Unordered(RCRecord x,RCRecord y)
{
  const Value *a=x,*b=y; int side; size_t i,j;
  if(!a || !b || a->kind!=Array || b->kind!=Array) return 0;
  for(side=0;side<2;side++) {
    const Value *from=side ? b : a,*to=side ? a : b;
    for(i=0;i<from->count;i++) { for(j=0;j<to->count;j++) if(Equal(from->items[i],to->items[j])) break; if(j==to->count) return 0; }
  }
  return 1;
}
static int Alarm(RCRecord a,RCRecord b) { (void)a; (void)b; return -1; }
static int Deleted(RCRecord r) { return r && ((const Value *)r)->kind==Tombstone; }
static const RCRecordAccess access;
static Value Scope(const Value *r,const Value *scope,Pair *pairs)
{
  size_t i; Value result={Record,NULL,0,0,pairs,NULL};
  if(!scope) return *r;
  for(i=0;i<scope->count;i++) {
    const char *key=scope->items[i]->text; const Value *v=Get(r,key);
    if(v) { pairs[result.count].key=key; pairs[result.count++].value=v; }
  }
  const char *entity="com.apple.syncservices.RecordEntityName"; const Value *v=Get(r,entity);
  if(v) { pairs[result.count].key=entity; pairs[result.count++].value=v; }
  return result;
}
static int Scoped(RCRecord a,RCRecord b,RCRecord fields)
{
  Pair ap[32],bp[32]; Value av=Scope(a,fields,ap),bv=Scope(b,fields,bp);
  return RCRecordsEqual(&av,&bv,&access);
}
static const RCRecordAccess access={Count,Keys,Next,Get,Text,Entity,PropertyEqual,Unordered,Alarm,Deleted,Scoped};
static int Records(const Value *a,const Value *b) { used=0; return RCRecordsEqual(a,b,&access); }
static void Receipts(void)
{
  Value contact=STR("com.apple.contacts.Contact"), old=STR("old"), newer=STR("new"), notes=STR("notes"), email=STR("email addresses");
  Value first=STR("first"),second=STR("second"); const Value *ab[]={&first,&second},*ba[]={&second,&first};
  Value forward=LIST(ab), reverse=LIST(ba);
  Pair before[]={{"com.apple.syncservices.RecordEntityName",&contact},{"notes",&old},{"email addresses",&forward}};
  Pair after[]={{"com.apple.syncservices.RecordEntityName",&contact},{"notes",&old},{"email addresses",&reverse}};
  Value a=MAP(before), b=MAP(after); CHECK(Records(&a,&b));
  /* The same order change in a recurrence array must not compare equal. */
  before[2].key=after[2].key="bydaydays"; CHECK(!Records(&a,&b));
  before[2].key=after[2].key="email addresses";
  after[1].value=&newer; CHECK(!Records(&a,&b));
  Pair receiptPairs[]={{"contact",&a}},currentPairs[]={{"contact",&b}};
  Value receipt=MAP(receiptPairs),current=MAP(currentPairs);
  const Value *fields[]={&email}; Value fieldList=LIST(fields);
  Pair scopePairs[]={{"contact",&fieldList}}; Value scopes=MAP(scopePairs);
  used=0; CHECK(RCReceiptMatches(&current,&receipt,&scopes,&access));
  fields[0]=&notes; used=0; CHECK(!RCReceiptMatches(&current,&receipt,&scopes,&access));
  used=0; CHECK(!RCReceiptMatches(&current,&receipt,NULL,&access));
  Value empty={Array,NULL,0,0,NULL,NULL},missing={Record,NULL,0,0,NULL,NULL},deleted={Tombstone,NULL,0,0,NULL,NULL};
  scopePairs[0].value=&empty; used=0; CHECK(RCReceiptMatches(&missing,&receipt,&scopes,&access));
  receiptPairs[0].value=&deleted; used=0; CHECK(!RCReceiptMatches(&current,&receipt,&scopes,&access));
  used=0; CHECK(RCReceiptMatches(&missing,&receipt,&scopes,&access));
  receiptPairs[0].value=&a; used=0; CHECK(!RCReceiptMatches(&missing,&receipt,NULL,&access));
  after[1].value=&old; used=0; CHECK(RCGraphsEqual(&current,&receipt,&access));
  currentPairs[0].key="unrelated"; used=0; CHECK(!RCGraphsEqual(&current,&receipt,&access));
  CHECK(!Records(&a,NULL)); CHECK(Records(NULL,NULL));
}
static void Defaults(void)
{
  Value event=STR("com.apple.calendars.Event"),zero=NUM(0),one=NUM(1),title=STR("Untitled event"),metadata=STR("native-only");
  Pair base[]={{"com.apple.syncservices.RecordEntityName",&event}};
  Pair populated[]={{"com.apple.syncservices.RecordEntityName",&event},{"all day",&zero},{"summary",&title},{"invitationId",&metadata}};
  Value a=MAP(base),b=MAP(populated); CHECK(Records(&a,&b));
  Value absent={Record,NULL,0,0,NULL,NULL};
  CHECK(!Records(&a,&absent)); CHECK(!Records(&absent,&a));
  populated[1].value=&one; CHECK(!Records(&a,&b));
  populated[1].value=&zero; populated[1].key="triggerduration"; CHECK(!Records(&a,&b));
  CHECK(!RCSyncFieldDefault("com.apple.calendars.AudioAlarm","triggerduration").present);
  CHECK(RCSyncFieldDefault("com.apple.calendars.Recurrence","interval").number==1);
  CHECK(!strcmp(RCSyncFieldDefault("com.apple.calendars.Attendee","status").text,"needsaction"));
  CHECK(!RCUnorderedField("bydayfreq") && RCUnorderedField("exception dates"));
  CHECK(!RCWritableFieldNames("future.Entity"));
  CHECK(!RCFieldListContains(RCWritableFieldNames("com.apple.calendars.Event"),"future field"));
  CHECK(RCFieldListContains(RCWritableFieldNames("com.apple.contacts.Contact"),"image"));
  CHECK(RCContactTypeSupported("com.apple.contacts.Phone Number","mobile"));
  CHECK(!RCContactTypeSupported("com.apple.contacts.Email Address","mobile"));
  CHECK(!RCContactTypeSupported("com.apple.contacts.Phone Number","unknown"));
  CHECK(!RCFollowChildRelationship("owner","com.apple.calendars.Event"));
  CHECK(!RCFollowChildRelationship("unknown","com.apple.contacts.Contact"));
  CHECK(RCFollowChildRelationship("future children","future.Child"));
  CHECK(!strcmp(RCIndependentFieldGroup("com.apple.calendars.AudioAlarm",0),"sound|com.apple.ical.sound"));
}
typedef struct { int working, supported, restored, rejected, attempts, failBaseline; } Plan;
static int Structure(void *p) { Plan *c=p; c->attempts++; return !c->failBaseline && !(c->working & ~c->supported); }
static void Restore(void *p) { Plan *c=p; c->restored++; c->working=0; }
static int Changed(void *p,size_t i) { (void)p; return i!=2; }
static int Encode(void *p,size_t i) { Plan *c=p; int candidate=c->working|(1<<(i+1)); c->attempts++; if(candidate & ~c->supported) return 0; c->working=candidate; return 1; }
static void Reject(void *p,size_t i) { Plan *c=p; c->rejected|=1<<(i+1); }
static void Planning(void)
{
  RCIndependentPlan ops={Structure,Restore,Changed,Encode,Reject};
  Plan c={1,2|16,0,0,0,0};
  CHECK(RCPlanIndependentFields(4,&ops,&c));
  CHECK(c.working==(2|16) && c.restored==1 && c.rejected==4 && c.attempts==5);
  c=(Plan){1,1|2|4|16,0,0,0,0}; CHECK(RCPlanIndependentFields(4,&ops,&c));
  CHECK(c.working==(1|2|4|16) && !c.restored && !c.rejected);
  c=(Plan){1,0,0,0,0,1}; CHECK(!RCPlanIndependentFields(4,&ops,&c)); CHECK(c.attempts==2 && !c.rejected);
}
int main(void) { Receipts(); Defaults(); Planning(); puts("Portable field capabilities, semantic records, exact receipts and partial-write planning passed."); return 0; }
