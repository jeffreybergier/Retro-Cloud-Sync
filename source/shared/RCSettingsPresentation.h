/* Presentation and validation shared by the AppKit and UIKit settings panes. */
#ifndef RC_SETTINGS_PRESENTATION_H
#define RC_SETTINGS_PRESENTATION_H
#import <Foundation/Foundation.h>
#include <signal.h>
#include <errno.h>

static inline BOOL RCStatusIsLive(NSDictionary *snapshot)
{
  int pid=[[snapshot objectForKey:@"PID"] intValue];
  return [[snapshot objectForKey:@"Running"] boolValue] && pid>0 &&
      (kill(pid,0)==0 || errno==EPERM);
}
static inline NSString *RCStatusErrorText(NSString *code)
{
  if([code isEqual:@"Credentials"]) return @"Saved password unavailable — check Keychain";
  if([code isEqual:@"Configuration"]) return @"Check your account settings — see Log";
  if([code isEqual:@"Database"]) return @"Could not open the sync database";
  if([code isEqual:@"Download"]) return @"Could not download from iCloud — see Log";
  if([code isEqual:@"Apply"]) return @"Could not apply local changes — see Log";
  if([code isEqual:@"Upload"]) return @"Could not finish uploading — see Log";
  return [code length] ? @"Sync failed — see Log" : nil;
}
static inline NSString *RCStatusChangesText(NSDictionary *service)
{
  long uploaded=[[service objectForKey:@"UploadedCount"] longValue];
  long attention=[[service objectForKey:@"AttentionCount"] longValue];
  if(uploaded>0 && attention>0)
    return [NSString stringWithFormat:@"%ld %@ uploaded to iCloud; %ld %@",uploaded,uploaded==1 ? @"change" : @"changes",attention,attention==1 ? @"item needs attention" : @"items need attention"];
  if(uploaded>0) {
    if([[service objectForKey:@"Phase"] isEqual:@"Uploaded"])
      return @"Uploaded to iCloud; local confirmation on next sync. No action needed.";
    return [NSString stringWithFormat:@"%ld %@ uploaded to iCloud; see current sync status",uploaded,uploaded==1 ? @"change" : @"changes"];
  }
  return [[service objectForKey:@"PendingCount"] description] ?: @"Unknown";
}
static inline NSString *RCStatusText(NSDictionary *service, BOOL live)
{
  NSString *phase=[service objectForKey:@"Phase"];
  if([phase isEqual:@"Disabled"]) return @"Disabled";
  if(!live && service) return @"Paused — background service stopped";
  NSString *error=RCStatusErrorText([service objectForKey:@"ErrorCode"]);
  if(error) return error;
  if([phase isEqual:@"UpToDate"]) return @"Up to date";
  if([phase isEqual:@"Stopping"]) return @"Stopping — saving progress…";
  if([phase isEqual:@"Waiting"]) return @"Waiting to sync";
  if([phase isEqual:@"Downloading"]) return @"Downloading from iCloud…";
  if([phase isEqual:@"Photos"]) return @"Checking contact photos…";
  if([phase isEqual:@"Applying"]) return @"Applying local changes…";
  if([phase isEqual:@"Uploading"]) return @"Uploading to iCloud…";
  if([phase isEqual:@"Uploaded"]) return @"Uploaded to iCloud";
  if([phase isEqual:@"Attention"]) return [[service objectForKey:@"UploadedCount"] longValue]>0 ? RCStatusChangesText(service) : @"Changes need attention";
  return @"Waiting for daemon status";
}
static inline NSString *RCIntervalText(NSInteger minutes)
{
  return [NSString stringWithFormat:minutes==1 ? @"%ld minute" : @"%ld minutes",(long)minutes];
}
static inline NSString *RCCalendarHistoryHelp(void)
{
  return @"All future events are included. Older imported events leave the local calendar; iCloud keeps them. Ongoing recurring series are kept in full.";
}
static inline NSString *RCSyncHelp(BOOL contacts)
{
  return contacts ? @"1-way: iCloud → device. 2-way: iCloud ↔ device. Two-way sync uploads supported contact additions, edits, and deletions. Unsupported changes remain pending; see Log." :
      @"1-way: iCloud → device. 2-way: iCloud ↔ device. Two-way sync uploads supported event additions, edits, and deletions in imported iCloud calendars. Recurrence structure changes remain pending; see Log.";
}
static inline NSString *RCMailFieldError(NSString *value, BOOL host, BOOL local)
{
  if(host) {
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    if(![value length] || [value rangeOfCharacterFromSet:[allowed invertedSet]].location!=NSNotFound)
      return @"Enter a server hostname without whitespace, a scheme, port, or path.";
  } else {
    int port=0;
    NSScanner *scanner=[NSScanner scannerWithString:value ? value : @""];
    [scanner setCharactersToBeSkipped:nil];
    BOOL parsed=[scanner scanInt:&port] && [scanner isAtEnd];
    if(!parsed || ![value length] || [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound || port<(local ? 1024 : 1) || port>65535)
      return @"Local ports must be 1024–65535. Server ports must be 1–65535.";
  }
  return nil;
}
#endif
