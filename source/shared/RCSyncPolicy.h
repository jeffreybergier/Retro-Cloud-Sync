#ifndef RC_SYNC_POLICY_H
#define RC_SYNC_POLICY_H
#include <stddef.h>
int RCFieldListContains(const char *,const char *);
const char *RCWritableFieldNames(const char *entity);
const char *RCIndependentFieldGroup(const char *entity,size_t index);
int RCContactTypeSupported(const char *entity,const char *type);
int RCFollowChildRelationship(const char *field,const char *childEntity);
int RCUnorderedField(const char *field);
int RCIgnoredNativeField(const char *entity,const char *field);
/* Defaults distinguish numeric zero from absent data. */
typedef struct { const char *text; int number, present; } RCFieldDefault;
RCFieldDefault RCSyncFieldDefault(const char *entity,const char *field);

/* Borrowed native records/keys. Adapters own allocation and platform value
   equality (including floating dates and sound URLs); C owns record/receipt
   decisions. Iterators must remain valid until the comparison returns. */
typedef const void *RCRecord;
typedef struct {
  size_t (*count)(RCRecord);
  void *(*keys)(RCRecord);
  RCRecord (*next)(void *);
  RCRecord (*get)(RCRecord,RCRecord);
  const char *(*text)(RCRecord);
  const char *(*entity)(RCRecord);
  int (*propertyEqual)(const char *,const char *,RCRecord,RCRecord);
  int (*unorderedEqual)(RCRecord,RCRecord);
  /* -1 means normalization unavailable; compare original sound fields. */
  int (*alarmEqual)(RCRecord,RCRecord);
  int (*tombstone)(RCRecord);
  int (*scopedEqual)(RCRecord,RCRecord,RCRecord);
} RCRecordAccess;
int RCRecordsEqual(RCRecord,RCRecord,const RCRecordAccess *);
int RCGraphsEqual(RCRecord,RCRecord,const RCRecordAccess *);
int RCReceiptMatches(RCRecord current,RCRecord receipt,RCRecord scopes,const RCRecordAccess *);

/* Retry atomic groups against one immutable resource. The adapter keeps the
   working graph/result and changes it only on successful encoding. */
typedef struct {
  int (*encodeStructure)(void *);
  void (*restoreStructure)(void *);
  int (*groupChanged)(void *,size_t);
  int (*encodeGroup)(void *,size_t);
  void (*rejectGroup)(void *,size_t);
} RCIndependentPlan;
int RCPlanIndependentFields(size_t groups,const RCIndependentPlan *,void *);
#endif
