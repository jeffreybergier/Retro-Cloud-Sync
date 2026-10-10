#import "RCIOSConfiguration.h"
#include <sys/stat.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

#ifdef RCIOS_UI_TESTS
NSString *const RCIOSSettingsDirectory=@"/var/mobile/Library/Caches/RetroCloudUITests";
#else
NSString *const RCIOSSettingsDirectory=@"/var/mobile/Library/Application Support/rCloud";
#endif
NSString *RCIOSConfigPath(void) { return [RCIOSSettingsDirectory stringByAppendingPathComponent:@"Config.plist"]; }
void RCIOSMessage(NSString *title,NSString *message) {
  UIAlertView *alert=[[UIAlertView alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
  [alert show]; [alert release];
}
/* The temporary file is private before writing, including on first setup. */
BOOL RCIOSSaveConfiguration(NSDictionary *config) {
  if(![[NSFileManager defaultManager] createDirectoryAtPath:RCIOSSettingsDirectory withIntermediateDirectories:YES
      attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions] error:NULL]) return NO;
  NSData *data=[NSPropertyListSerialization dataFromPropertyList:config format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL];
  if(!data) return NO;
  char *name=strdup([[RCIOSConfigPath() stringByAppendingString:@".XXXXXX"] fileSystemRepresentation]);
  if(!name) return NO;
  int fd=mkstemp(name); BOOL ok=fd>=0; NSUInteger left=[data length]; const char *bytes=[data bytes];
  while(ok && left) { ssize_t n=write(fd,bytes,left); if(n<0 && errno==EINTR) continue;
    if(n<=0) { ok=NO; break; } bytes+=n; left-=n; }
  if(fd>=0) { if(fsync(fd)) ok=NO; if(close(fd)) ok=NO; }
  if(ok) ok=rename(name,[RCIOSConfigPath() fileSystemRepresentation])==0;
  if(!ok) unlink(name); free(name); return ok;
}
