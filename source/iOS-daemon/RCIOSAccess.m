#import "RCIOSAccess.h"
#import <EventKit/EventKit.h>
ABAddressBookRef RCIOSCreateAddressBook(CFErrorRef *error)
{
  if(&ABAddressBookCreateWithOptions) return ABAddressBookCreateWithOptions(NULL,error);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return ABAddressBookCreate();
#pragma clang diagnostic pop
}
BOOL RCIOSWaitForAccess(BOOL contacts,RCError *error)
{
  RCErrorClear(error);
  BOOL allowed=contacts ? (!&ABAddressBookGetAuthorizationStatus || ABAddressBookGetAuthorizationStatus()==kABAuthorizationStatusAuthorized) :
      (![EKEventStore respondsToSelector:@selector(authorizationStatusForEntityType:)] ||
       [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent]==EKAuthorizationStatusAuthorized);
  if(!allowed) RCErrorSet(error,1,"%s access unavailable; open rCloud and allow access in Settings > Privacy",contacts ? "Contacts" : "Calendar");
  return allowed;
}
/* A registered app executable can request normal system privacy prompts from
   launchd as mobile. Each enabled service is requested once per process. */
void RCIOSRequestAccess(BOOL contacts,BOOL calendars)
{
  static BOOL requestedContacts=NO,requestedCalendars=NO;
  @synchronized([EKEventStore class]) {
    contacts=contacts && !requestedContacts; calendars=calendars && !requestedCalendars;
    if(contacts) requestedContacts=YES; if(calendars) requestedCalendars=YES;
  }
  if(contacts && &ABAddressBookRequestAccessWithCompletion && ABAddressBookGetAuthorizationStatus()==kABAuthorizationStatusNotDetermined) {
    ABAddressBookRef book=RCIOSCreateAddressBook(NULL);
    if(book) ABAddressBookRequestAccessWithCompletion(book,^(bool granted,CFErrorRef error) {
      (void)granted; (void)error; CFRelease(book);
    });
  }
  if(calendars && [EKEventStore respondsToSelector:@selector(authorizationStatusForEntityType:)] &&
      [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent]==EKAuthorizationStatusNotDetermined) {
    EKEventStore *store=[[EKEventStore alloc] init];
    [store requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted,NSError *error) {
      (void)granted; (void)error; [store release];
    }];
  }
}
void RCIOSPromptForAccess(void) { RCIOSRequestAccess(YES,YES); }
