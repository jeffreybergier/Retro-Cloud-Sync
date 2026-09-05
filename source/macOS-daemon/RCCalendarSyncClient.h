#ifndef RC_CALENDAR_SYNC_CLIENT_H
#define RC_CALENDAR_SYNC_CLIENT_H

#import <Foundation/Foundation.h>

static inline NSString *RCCalendarSyncClientIdentifier(NSString *accountSyncID)
{
  /* Tiger hex-encodes each UTF-16 code unit as four filename characters.
     With the full 32-character account ID, this is 58 * 4 = 232 bytes.
     The former "calendars" prefix produced 256, exceeding NAME_MAX (255). */
  return [@"com.retrocloudsync.cal.v1." stringByAppendingString:accountSyncID];
}

#endif
