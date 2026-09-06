#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>
#include <stdio.h>
#include <string.h>
static NSString *Entity(NSString *name)
{
  return [@"com.apple.calendars." stringByAppendingString:name];
}
int main(int argc, char **argv)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  ISyncManager *manager = [ISyncManager sharedManager];
  NSArray *entities = [NSArray
      arrayWithObjects:Entity(@"Calendar"), Entity(@"Event"), Entity(@"Recurrence"),
                       Entity(@"DisplayAlarm"), Entity(@"Attendee"), nil];
  ISyncRecordSnapshot *snapshot =
      [manager snapshotOfRecordsInTruthWithEntityNames:entities
                             usingIdentifiersForClient:nil];
  NSDictionary *events = [snapshot
      recordsWithMatchingAttributes:[NSDictionary
                                        dictionaryWithObject:Entity(@"Event")
                                                      forKey:ISyncRecordEntityNameKey]];
  NSDictionary *calendars = [snapshot
      recordsWithMatchingAttributes:[NSDictionary
                                        dictionaryWithObject:Entity(@"Calendar")
                                                      forKey:ISyncRecordEntityNameKey]];
  NSMutableDictionary *testEvents = [NSMutableDictionary dictionary];
  NSMutableArray *baseline = [NSMutableArray array];
  NSEnumerator *keys = [events keyEnumerator];
  NSString *key;
  int testCalendars = 0, ok = 0;
  while ((key = [keys nextObject])) {
    NSDictionary *event = [events objectForKey:key];
    NSString *title = [event objectForKey:@"summary"];
    if ([title hasPrefix:@"RCS Calendar Test "]) {
      if ([testEvents objectForKey:title]) {
        fprintf(stderr, "Duplicate synthetic event\n");
        goto done;
      }
      [testEvents setObject:event forKey:title];
    } else
      [baseline addObject:key];
  }
  keys = [calendars keyEnumerator];
  while ((key = [keys nextObject])) {
    if ([[[calendars objectForKey:key] objectForKey:@"title"]
            hasPrefix:@"RCS Calendar Test"])
      testCalendars++;
    else
      [baseline addObject:key];
  }
  if (argc == 3 && !strcmp(argv[1], "snapshot")) {
    ok = [baseline writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
    goto done;
  }
  if (argc == 3 && !strcmp(argv[1], "baseline")) {
    NSArray *previous =
        [NSArray arrayWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
    NSEnumerator *i = [previous objectEnumerator];
    NSString *id;
    ok = previous != nil;
    while ((id = [i nextObject]))
      if (![baseline containsObject:id])
        ok = 0;
    goto done;
  }
  if (argc == 2 && !strcmp(argv[1], "diagnose")) {
    ISyncClient *ical = [manager clientWithIdentifier:@"com.apple.iCal"];
    NSLog(@"Test client=%@",
          [manager clientWithIdentifier:@"com.retrocloudsync.calendars.test.v1"]);
    NSLog(@"iCal enabled=%lu calendars=%lu events=%lu",
          (unsigned long)[[ical enabledEntityNames] count],
          (unsigned long)[calendars count], (unsigned long)[events count]);
    NSLog(@"Synthetic truth calendars=%d events=%@", testCalendars, testEvents);
    NSEnumerator *iterator = [calendars keyEnumerator];
    NSString *id;
    while ((id = [iterator nextObject])) {
      NSDictionary *cal = [calendars objectForKey:id];
      if ([[cal objectForKey:@"title"] hasPrefix:@"RCS Calendar Test"])
        NSLog(@"Test calendar id=%@ title=%@ readonly=%@", id,
              [cal objectForKey:@"title"], [cal objectForKey:@"read only"]);
    }
    ok = 1;
    goto done;
  }
  if (argc == 2 && !strcmp(argv[1], "empty")) {
    ok = testCalendars == 0 && [testEvents count] == 0;
    goto done;
  }
  if (argc == 2) {
    BOOL updated = !strcmp(argv[1], "updated");
    NSDictionary *day = [testEvents objectForKey:@"RCS Calendar Test All Day"];
    NSDictionary *weekly =
        [testEvents objectForKey:updated ? @"RCS Calendar Test Edited"
                                         : @"RCS Calendar Test Weekly"];
    NSDictionary *moved = [testEvents objectForKey:@"RCS Calendar Test Moved"];
    NSDictionary *single = [testEvents objectForKey:@"RCS Calendar Test Single"];
    NSDictionary *alarm =
        [[[snapshot recordsWithIdentifiers:[weekly objectForKey:@"display alarms"]]
            allValues] lastObject];
    NSDictionary *attendee =
        [[[snapshot recordsWithIdentifiers:[weekly objectForKey:@"attendees"]]
            allValues] lastObject];
    NSCalendarDate *start = [day objectForKey:@"start date"],
                   *end = [day objectForKey:@"end date"];
    ok = testCalendars == 1 && [testEvents count] == (updated ? 4 : 5) &&
         [[day objectForKey:@"all day"] boolValue] && [start yearOfCommonEra] == 2030 &&
         [start dayOfMonth] == 20 && [end dayOfMonth] == 22 && weekly && moved &&
         [[weekly objectForKey:@"recurrences"] count] == 1 &&
         [[weekly objectForKey:@"detached events"] count] == 1 &&
         [[weekly objectForKey:@"exception dates"] count] == 1 &&
         [[moved objectForKey:@"main event"] count] == 1 &&
         [[weekly objectForKey:@"display alarms"] count] == 1 &&
         [[alarm objectForKey:@"triggerduration"] intValue] == -900 &&
         [[weekly objectForKey:@"attendees"] count] == 1 &&
         [[attendee objectForKey:@"status"] isEqual:@"accepted"] &&
         (updated ||
          ([[single objectForKey:@"start date"] yearOfCommonEra] == 2040 &&
           [[single objectForKey:@"end date"]
               timeIntervalSinceDate:[single objectForKey:@"start date"]] == 3600));
  }
done:
  if (!ok)
    fprintf(stderr, "Calendar verification failed: %s (calendars=%d events=%lu)\n",
            argc > 1 ? argv[1] : "missing phase", testCalendars,
            (unsigned long)[testEvents count]);
  [pool release];
  return ok ? 0 : 1;
}
