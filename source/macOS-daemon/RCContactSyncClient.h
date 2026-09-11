#ifndef RC_CONTACT_SYNC_CLIENT_H
#define RC_CONTACT_SYNC_CLIENT_H

#import <Foundation/Foundation.h>

static inline NSString *RCContactSyncClientIdentifier(NSString *accountSyncID)
{
  /* Tiger expands each UTF-16 code unit to four filename bytes. Keep this
     prefix short enough for the full 32-character account identity. */
  return [@"com.altivecintelligence.ct.v1." stringByAppendingString:accountSyncID];
}

#endif
