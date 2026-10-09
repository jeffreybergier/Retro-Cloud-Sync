#import <Foundation/Foundation.h>
#import <AddressBook/AddressBook.h>
#import <EventKit/EventKit.h>
#include <stdio.h>
#include <unistd.h>

/* Metadata only: no permission requests, record bodies, save/remove calls,
   account refreshes, or direct access to system databases. */
static ABAddressBookRef CreateBook(CFErrorRef *error)
{
  if (&ABAddressBookCreateWithOptions != NULL)
    return ABAddressBookCreateWithOptions(NULL, error);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return ABAddressBookCreate();
#pragma clang diagnostic pop
}

static NSArray *Calendars(EKEventStore *store)
{
  if ([store respondsToSelector:@selector(calendarsForEntityType:)])
    return [store calendarsForEntityType:EKEntityTypeEvent];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return [store calendars];
#pragma clang diagnostic pop
}

static void Contacts(void)
{
  BOOL legacy = &ABAddressBookGetAuthorizationStatus == NULL;
  ABAuthorizationStatus status = legacy ? kABAuthorizationStatusAuthorized :
      ABAddressBookGetAuthorizationStatus();
  printf("contacts.authorization=%s\n", legacy ? "legacy-no-status-api" :
      status == kABAuthorizationStatusAuthorized ? "authorized" :
      status == kABAuthorizationStatusDenied ? "denied" :
      status == kABAuthorizationStatusRestricted ? "restricted" : "not-determined");
  if (status != kABAuthorizationStatusAuthorized) return;
  CFErrorRef error = NULL;
  ABAddressBookRef book = CreateBook(&error);
  printf("contacts.store=%s error=%ld\n", book ? "available" : "unavailable",
      error ? (long)CFErrorGetCode(error) : 0L);
  if (book) {
    CFArrayRef sources = ABAddressBookCopyArrayOfAllSources(book);
    CFIndex count = sources ? CFArrayGetCount(sources) : 0, local = 0;
    for (CFIndex i = 0; i < count; i++) {
      ABRecordRef source = CFArrayGetValueAtIndex(sources, i);
      CFNumberRef value = ABRecordCopyValue(source, kABSourceTypeProperty);
      int type = -1;
      if (value) {
        CFNumberGetValue(value, kCFNumberIntType, &type);
        CFRelease(value);
      }
      if (type == kABSourceTypeLocal) local++;
    }
    printf("contacts.sources=%ld local_sources=%ld\n", (long)count, (long)local);
    if (sources) CFRelease(sources);
    CFRelease(book);
  }
  if (error) CFRelease(error);
}

static void CalendarAccess(void)
{
  BOOL legacy = ![EKEventStore respondsToSelector:@selector(authorizationStatusForEntityType:)];
  EKAuthorizationStatus status = legacy ? EKAuthorizationStatusAuthorized :
      [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
  printf("calendars.authorization=%s\n", legacy ? "legacy-no-status-api" :
      status == EKAuthorizationStatusAuthorized ? "authorized" :
      status == EKAuthorizationStatusDenied ? "denied" :
      status == EKAuthorizationStatusRestricted ? "restricted" : "not-determined");
  if (status != EKAuthorizationStatusAuthorized) return;
  EKEventStore *store = [[EKEventStore alloc] init];
  printf("calendars.store=%s\n", store ? "available" : "unavailable");
  if (store) {
    NSArray *sources = [store sources];
    NSUInteger local = 0, writableLocal = 0;
    for (EKSource *source in sources)
      if ([source sourceType] == EKSourceTypeLocal) local++;
    NSArray *calendars = Calendars(store);
    for (EKCalendar *calendar in calendars)
      if ([[calendar source] sourceType] == EKSourceTypeLocal &&
          [calendar allowsContentModifications]) writableLocal++;
    printf("calendars.sources=%lu local_sources=%lu calendars=%lu writable_local_calendars=%lu\n",
        (unsigned long)[sources count], (unsigned long)local,
        (unsigned long)[calendars count], (unsigned long)writableLocal);
  }
  [store release];
}

int main(void)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  setvbuf(stdout, NULL, _IONBF, 0);
  /* Bound a stuck framework connection; no cleanup-sensitive mutations occur. */
  alarm(20);
  printf("probe.version=1 uid=%lu euid=%lu pointer_bits=%lu\n",
      (unsigned long)getuid(), (unsigned long)geteuid(),
      (unsigned long)(sizeof(void *) * 8));
  int result = 0;
  @try { Contacts(); CalendarAccess(); }
  @catch (NSException *exception) {
    (void)exception;
    puts("probe.error=framework-exception"); result = 1;
  }
  alarm(0);
  [pool drain];
  return result;
}
