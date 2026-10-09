#import <Foundation/Foundation.h>
#import <AddressBook/AddressBook.h>
#include "RCError.h"
ABAddressBookRef RCIOSCreateAddressBook(CFErrorRef *error);
BOOL RCIOSWaitForAccess(BOOL contacts,RCError *error);
void RCIOSRequestAccess(BOOL contacts,BOOL calendars);
void RCIOSPromptForAccess(void);
