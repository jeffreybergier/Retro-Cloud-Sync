#import <UIKit/UIKit.h>
#import "RCIOSAccess.h"
#import "RCIOSSettings.h"
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include "RCICloudCredentials.h"
#ifdef RCIOS_NATIVE_TESTS
int RCIOSNativeTests(const char *directory);
#endif
int RCCloudDaemonMain(int argc,char **argv);
@interface RCIOSSetup : UIResponder <UIApplicationDelegate> { UIWindow *window_; }
@end
@implementation RCIOSSetup
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  (void)application; (void)options;
  window_=[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  [window_ setRootViewController:RCIOSRootController()];
  [window_ makeKeyAndVisible];
#ifdef RCIOS_UI_TESTS
  [self performSelector:@selector(runUITests) withObject:nil afterDelay:1];
#endif
  return YES;
}
#ifdef RCIOS_UI_TESTS
- (void)runUITests { extern void RCIOSRunUITests(UIWindow *); RCIOSRunUITests(window_); }
#endif
- (void)dealloc { [window_ release]; [super dealloc]; }
@end
int main(int argc,char **argv) {
  if(getuid()!=501) { fputs("Run rCloud as mobile.\n",stderr); return 1; }
  if(argc==3 && !strcmp(argv[1],"--set-password")) {
    /* Passwords arrive over stdin, never in argv, a plist or daemon logging. */
    if(getuid()!=501 || isatty(STDIN_FILENO)) { fputs("Run as mobile and pipe the password on stdin.\n",stderr); return 1; }
    char password[4097]; size_t length=fread(password,1,sizeof(password),stdin);
    if(length && password[length-1]=='\n') length--;
    RCError error; int ok=length>0 && length<sizeof(password) &&
        RCICloudCredentialsSave(argv[2],password,length,"/Applications/rCloud.app/rCloud",&error);
    volatile char *clear=password; for(size_t n=0;n<sizeof(password);n++) clear[n]=0;
    fputs(ok ? "Password saved in Keychain.\n" : "Could not save password.\n",ok ? stdout : stderr); return ok ? 0 : 1;
  }
  if(argc==2 && !strcmp(argv[1],"--daemon")) {
    const char *path="/var/mobile/Library/Application Support/rCloud/Config.plist";
    if(access(path,R_OK)!=0) { puts("rCloud is not configured."); return 0; }
    char *arguments[]={argv[0],"--config",(char *)path,NULL};
    umask(0077); return RCCloudDaemonMain(3,arguments);
  }
#ifdef RCIOS_NATIVE_TESTS
  if(argc==3 && !strcmp(argv[1],"--native-tests")) return RCIOSNativeTests(argv[2]);
#endif
  if(argc==2 && (!strcmp(argv[1],"--access") || !strcmp(argv[1],"--request-access"))) {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    if(!strcmp(argv[1],"--request-access")) {
      RCIOSPromptForAccess(); NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:60];
      while([deadline timeIntervalSinceNow]>0) {
        RCError access; if(RCIOSWaitForAccess(YES,&access) && RCIOSWaitForAccess(NO,&access)) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
      }
    }
    RCError error; BOOL contacts=RCIOSWaitForAccess(YES,&error),calendars=RCIOSWaitForAccess(NO,&error);
    printf("Contacts: %s\nCalendar: %s\n",contacts ? "authorized" : "unavailable",calendars ? "authorized" : "unavailable");
    [pool drain]; return contacts && calendars ? 0 : 1;
  }
  if(argc>1) return RCCloudDaemonMain(argc,argv);
  NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
  int result=UIApplicationMain(argc,argv,nil,@"RCIOSSetup"); [pool drain]; return result;
}
