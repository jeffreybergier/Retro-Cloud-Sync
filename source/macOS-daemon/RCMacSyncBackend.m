#import "RCMacNativeBackend.h"
#if defined(__LP64__)
#import <CoreServices/CoreServices.h>
#endif
extern const RCSyncBackend RCSyncServicesBackend;
extern const RCSyncBackend RCMacNativeBackend;
BOOL RCUsesNativeStoresForVersion(int major,int minor)
{ return major>10 || (major==10 && minor>=9); }
BOOL RCUsesNativeStores(void)
{
#if defined(__LP64__)
  SInt32 major=0,minor=0;
  return Gestalt(gestaltSystemVersionMajor,&major)==noErr &&
      Gestalt(gestaltSystemVersionMinor,&minor)==noErr && RCUsesNativeStoresForVersion(major,minor);
#else
  return NO;
#endif
}
const RCSyncBackend *RCCurrentSyncBackend(void)
{ return RCUsesNativeStores() ? &RCMacNativeBackend : &RCSyncServicesBackend; }
