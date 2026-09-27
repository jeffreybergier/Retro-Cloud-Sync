#include "RCSyncPolicy.h"
#include <string.h>
static int Is(const char *a,const char *b) { return a && !strcmp(a,b); }
int RCFieldListContains(const char *list,const char *field)
{
  size_t n;
  if(!list || !field) return 0;
  n=strlen(field);
  while(*list) {
    const char *end=strchr(list,'|'); size_t length=end ? (size_t)(end-list) : strlen(list);
    if(length==n && !strncmp(list,field,n)) return 1;
    if(!end) break;
    list=end+1;
  }
  return 0;
}
const char *RCWritableFieldNames(const char *entity)
{
  static const struct { const char *entity, *fields; } entries[]={
    {"com.apple.contacts.Contact","first name|last name|middle name|title|suffix|nickname|company name|department|job title|birthday|notes|image|first name yomi|middle name yomi|last name yomi|company name yomi|dates|related names|IMs|primary phone number|primary email address|primary street address|primary URL|display as company|phone numbers|email addresses|street addresses|URLs"},
    {"com.apple.contacts.Street Address","contact|street|city|state|postal code|country|country code|type|label"},
    {"com.apple.contacts.Phone Number","contact|value|type|label"},
    {"com.apple.contacts.Email Address","contact|value|type|label"},
    {"com.apple.contacts.URL","contact|value|type|label"},
    {"com.apple.contacts.Date","contact|value|type|label"},
    {"com.apple.contacts.Related Name","contact|value|type|label"},
    {"com.apple.contacts.IM","contact|user|service|type|label"},
    {"com.apple.calendars.Event","summary|description|location|url|status|classification|calendar|main event|original date|start date|end date|all day|exception dates|detached events|recurrences|attendees|organizer|display alarms|audio alarms"},
    {"com.apple.calendars.Recurrence","owner|frequency|interval|count|until|bymonth|bymonthday|byyearday|byweeknumber|bysetpos|bydaydays|bydayfreq|weekstartday"},
    {"com.apple.calendars.Attendee","owner|email|common name|role|status|user type|rsvp"},
    {"com.apple.calendars.Organizer","owner|email|common name|role|status|user type|rsvp"},
    {"com.apple.calendars.AudioAlarm","owner|description|triggerdate|triggerduration|repeat count|repeat interval|sound|com.apple.ical.sound"},
    {"com.apple.calendars.DisplayAlarm","owner|description|triggerdate|triggerduration|repeat count|repeat interval|sound|com.apple.ical.sound"},
  };
  size_t i;
  for(i=0;i<sizeof(entries)/sizeof(*entries);i++) if(Is(entity,entries[i].entity)) return entries[i].fields;
  return NULL;
}
const char *RCIndependentFieldGroup(const char *entity,size_t index)
{
  if(Is(entity,"com.apple.contacts.Contact")) {
    static const char *groups[]={"first name|last name|middle name|title|suffix","company name|department","first name yomi","middle name yomi","last name yomi","company name yomi","notes","image","job title","nickname","birthday","display as company"};
    return index<sizeof(groups)/sizeof(*groups) ? groups[index] : NULL;
  }
  if(Is(entity,"com.apple.contacts.Street Address")) {
    static const char *groups[]={"street|city|state|postal code|country"};
    return index<sizeof(groups)/sizeof(*groups) ? groups[index] : NULL;
  }
  if(Is(entity,"com.apple.contacts.Phone Number") || Is(entity,"com.apple.contacts.Email Address") || Is(entity,"com.apple.contacts.URL")) {
    static const char *groups[]={"value"};
    return index<sizeof(groups)/sizeof(*groups) ? groups[index] : NULL;
  }
  if(Is(entity,"com.apple.calendars.Event")) {
    static const char *groups[]={"summary","description","location","url","status","classification"};
    return index<sizeof(groups)/sizeof(*groups) ? groups[index] : NULL;
  }
  if(Is(entity,"com.apple.calendars.AudioAlarm")) {
    static const char *groups[]={"sound|com.apple.ical.sound"};
    return index<sizeof(groups)/sizeof(*groups) ? groups[index] : NULL;
  }
  return NULL;
}
int RCContactTypeSupported(const char *entity,const char *type)
{
  if(RCFieldListContains("home|work|other",type)) return 1;
  if(Is(entity,"com.apple.contacts.Phone Number")) return RCFieldListContains("mobile|pager|home fax|work fax",type);
  if(Is(entity,"com.apple.contacts.URL")) return Is(type,"home page");
  if(Is(entity,"com.apple.contacts.Date")) return Is(type,"anniversary");
  return Is(entity,"com.apple.contacts.Related Name") && RCFieldListContains("father|mother|parent|child|brother|sister|friend|spouse|partner|assistant|manager",type);
}
int RCFollowChildRelationship(const char *field,const char *entity)
{
  return !RCFieldListContains("contact|owner|calendar|main event|parent groups",field) &&
      !Is(entity,"com.apple.calendars.Calendar") && !Is(entity,"com.apple.contacts.Contact");
}
int RCUnorderedField(const char *field)
{
  return RCFieldListContains("phone numbers|email addresses|street addresses|URLs|events|tasks|detached events|exception dates|attendees|organizer|recurrences|display alarms|audio alarms|mail alarms",field);
}
int RCIgnoredNativeField(const char *entity,const char *field)
{
  return Is(entity,"com.apple.calendars.Event") && RCFieldListContains("com.apple.ical.uid|com.apple.ical.sequence|invitationId|invitationSequence|invitationTimestamp",field);
}
RCFieldDefault RCSyncFieldDefault(const char *entity,const char *field)
{
  RCFieldDefault result={NULL,0,1};
  if(Is(entity,"com.apple.calendars.Event")) {
    if(Is(field,"summary")) result.text="Untitled event";
    else if(Is(field,"all day")) result.number=0;
    else if(Is(field,"status")) result.text="none";
    else if(Is(field,"classification")) result.text="public";
    else result.present=0;
  } else if(Is(entity,"com.apple.calendars.Recurrence")) {
    if(Is(field,"interval")) result.number=1;
    else if(Is(field,"count")) result.number=0;
    else if(Is(field,"weekstartday")) result.text="monday";
    else result.present=0;
  } else if(Is(entity,"com.apple.calendars.Attendee")) {
    if(Is(field,"rsvp")) result.number=0;
    else if(Is(field,"role")) result.text="requiredparticipant";
    else if(Is(field,"status")) result.text="needsaction";
    else if(Is(field,"user type")) result.text="individual";
    else result.present=0;
  } else if(Is(entity,"com.apple.contacts.Contact") && Is(field,"display as company")) result.text="person";
  else if(RCFieldListContains("com.apple.contacts.Phone Number|com.apple.contacts.Email Address|com.apple.contacts.Street Address|com.apple.contacts.URL|com.apple.contacts.Date|com.apple.contacts.Related Name|com.apple.contacts.IM",entity) && Is(field,"type")) result.text="other";
  else result.present=0;
  return result;
}
int RCRecordsEqual(RCRecord a,RCRecord b,const RCRecordAccess *ops)
{
  const char *entity; int alarm=-1, side;
  if(!a || !b) return a==b;
  entity=ops->entity(a);
  if(!Is(entity,ops->entity(b))) entity=NULL;
  if(Is(entity,"com.apple.calendars.AudioAlarm")) {
    alarm=ops->alarmEqual(a,b);
    if(alarm==0) return 0;
  }
  for(side=0;side<2;side++) {
    void *keys=ops->keys(side ? b : a); RCRecord key;
    while((key=ops->next(keys))) {
      const char *name=ops->text(key);
      RCRecord x=ops->get(a,key), y=ops->get(b,key);
      if(side && x) continue;
      if(RCIgnoredNativeField(entity,name)) continue;
      if(alarm==1 && (Is(name,"sound") || Is(name,"com.apple.ical.sound"))) continue;
      if(ops->propertyEqual(entity,name,x,y)) continue;
      if(RCUnorderedField(name) && ops->unorderedEqual(x,y)) continue;
      return 0;
    }
  }
  return 1;
}
int RCGraphsEqual(RCRecord a,RCRecord b,const RCRecordAccess *ops)
{
  RCRecord key; void *keys;
  if(!a || !b) return a==b;
  if(ops->count(a)!=ops->count(b)) return 0;
  keys=ops->keys(a);
  while((key=ops->next(keys))) if(!RCRecordsEqual(ops->get(a,key),ops->get(b,key),ops)) return 0;
  return 1;
}
int RCReceiptMatches(RCRecord current,RCRecord receipt,RCRecord scopes,const RCRecordAccess *ops)
{
  RCRecord key; void *keys=ops->keys(receipt);
  while((key=ops->next(keys))) {
    RCRecord expected=ops->get(receipt,key), record=ops->get(current,key), fields=ops->get(scopes,key);
    if(ops->tombstone(expected)) { if(record) return 0; continue; }
    if(fields && !ops->count(fields)) continue;
    if(!record || !ops->scopedEqual(record,expected,fields)) return 0;
  }
  return 1;
}
int RCPlanIndependentFields(size_t groups,const RCIndependentPlan *ops,void *context)
{
  size_t i;
  if(!ops->encodeStructure(context)) {
    ops->restoreStructure(context);
    if(!ops->encodeStructure(context)) return 0;
  }
  for(i=0;i<groups;i++) if(ops->groupChanged(context,i) && !ops->encodeGroup(context,i)) ops->rejectGroup(context,i);
  return 1;
}
