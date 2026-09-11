#ifndef RC_CALENDAR_SYNC_CLIENT_H
#define RC_CALENDAR_SYNC_CLIENT_H

#import <Foundation/Foundation.h>
#include "../shared/RCWriteJournal.h"

static inline NSString *RCCalendarSyncClientIdentifier(NSString *accountSyncID)
{
  /* Tiger hex-encodes each UTF-16 code unit as four filename characters.
     With the full 32-character account ID, this is 58 * 4 = 232 bytes.
     The former "calendars" prefix produced 256, exceeding NAME_MAX (255). */
  return [@"com.retrocloudsync.cal.v1." stringByAppendingString:accountSyncID];
}

static inline NSString *RCCalendarNativeTitle(RCWriteJournal journal,NSString *identifier,NSString *title)
{
  sqlite3_stmt *q=NULL; BOOL createdLocally=NO;
  if(sqlite3_prepare_v2(journal.db,"SELECT 1 FROM two_way_aliases WHERE account_id=? AND imported_id=?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,journal.account); sqlite3_bind_text(q,2,[identifier UTF8String],-1,SQLITE_TRANSIENT);
    createdLocally=sqlite3_step(q)==SQLITE_ROW;
  }
  sqlite3_finalize(q);
  /* A locally created calendar already owns its native identity and title. */
  return createdLocally ? (title ?: @"Calendar") : [NSString stringWithFormat:@"%@ (iCloud %@)",title ?: @"Calendar",[identifier substringFromIndex:[identifier length]-6]];
}
#endif
