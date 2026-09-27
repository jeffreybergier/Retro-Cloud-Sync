#include "RCStatusPolicy.h"
#include <stddef.h>

/* Missing optional tables precede first two-way sync. Any query failure is unknown,
   never evidence that all changes have completed. Counts describe pending items. */
static long Count(RCWriteJournal *j, const char *table, const char *sql)
{
  sqlite3_stmt *q=NULL; long result=-1;
  if(sqlite3_prepare_v2(j->db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",-1,&q,NULL)!=SQLITE_OK) return -1;
  sqlite3_bind_text(q,1,table,-1,SQLITE_STATIC); int step=sqlite3_step(q); sqlite3_finalize(q);
  if(step==SQLITE_DONE) return 0;
  if(step!=SQLITE_ROW) return -1;
  if(sqlite3_prepare_v2(j->db,sql,-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account);
    if(sqlite3_step(q)==SQLITE_ROW) result=sqlite3_column_int64(q,0);
  }
  sqlite3_finalize(q); return result;
}
RCStatusResult RCStatusEvaluate(RCWriteJournal *j, int contacts, int complete, int failed, int stopping)
{
  const char *tables[]={"write_operations","two_way_pending_fields","two_way_attention","calendar_actions"};
  const char *queries[]={
    "SELECT count(*) FROM write_operations WHERE account_id=? AND state NOT IN ('acknowledged','cancelled')",
    "SELECT count(*) FROM two_way_pending_fields WHERE account_id=?",
    "SELECT count(*) FROM two_way_attention WHERE account_id=?",
    "SELECT count(*) FROM calendar_actions WHERE account_id=? AND state<>'done'"};
  long count=0; int known=1; int i;
  for(i=0;i<4;i++) { long n=Count(j,tables[i],queries[i]); if(n<0) known=0; else count+=n; }
  long invalid=Count(j,contacts ? "contacts" : "calendar_resources",
      contacts ?
      "SELECT count(*) FROM contacts c JOIN collections b ON b.id=c.collection_id WHERE b.account_id=? AND c.remote_missing=0 AND c.parse_error IS NOT NULL" :
      "SELECT count(*) FROM calendar_resources r JOIN calendars c ON c.id=r.calendar_id WHERE c.account_id=? AND r.remote_missing=0 AND r.scope_excluded=0 AND (r.parse_error IS NOT NULL OR r.export_status IN ('unsupported','retained previous'))");
  if(invalid<0) known=0; else count+=invalid;
  RCStatusResult result;
  result.pending=count;
  result.known=known;
  result.phase=stopping ? "Stopping" : failed ? "Error" :
      (!complete || !known || count) ? "Attention" : "UpToDate";
  result.severity=stopping ? "yellow" : failed ? "red" :
      (!complete || !known || count) ? "yellow" : "green";
  result.advanceSuccess=!stopping && !failed && complete && known && count==0;
  return result;
}
