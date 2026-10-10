#import "RCIOSConfiguration.h"
#import "RCSettingsPresentation.h"
#import "RCLogTable.h"

@implementation RCLogTable
- (void)viewDidLoad { [super viewDidLoad]; [self setTitle:@"Log"]; [[self navigationItem] setRightBarButtonItem:[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)] autorelease]]; [self refresh]; }
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated]; [self refresh];
  [refreshTimer_ invalidate]; [refreshTimer_ release];
  refreshTimer_=[[NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES] retain];
}
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated]; [refreshTimer_ invalidate]; [refreshTimer_ release]; refreshTimer_=nil;
}
- (void)refresh {
  NSFileHandle *file=[NSFileHandle fileHandleForReadingAtPath:@"/var/mobile/Library/Logs/RetroCloudSync/RetroCloudSyncDaemon.log"];
  NSString *tail=nil;
  @try { unsigned long long size=[file seekToEndOfFile]; [file seekToFileOffset:size>1048576 ? size-1048576 : 0];
    NSData *data=[file readDataOfLength:1048576]; tail=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if(!tail && data) tail=[[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
    if(size>1048576) { NSRange newline=[tail rangeOfString:@"\n"]; if(newline.location!=NSNotFound) tail=[tail substringFromIndex:newline.location+1]; tail=[@"[Earlier log entries are not shown.]\n" stringByAppendingString:tail ?: @""]; }
  } @catch(NSException *exception) { (void)exception; tail=@"Log unavailable."; } @finally { [file closeFile]; }
  [lines_ release]; lines_=[[(tail ? tail : @"No log yet.") componentsSeparatedByString:@"\n"] copy]; [[self tableView] reloadData];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; (void)section; return [lines_ count]; }
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
  /* Measure with UIKit's default label font, also available on iOS 5. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CGSize size=[[lines_ objectAtIndex:[path row]] sizeWithFont:[UIFont systemFontOfSize:[UIFont labelFontSize]]
      constrainedToSize:CGSizeMake(MAX(1,CGRectGetWidth([table bounds])-30),CGFLOAT_MAX) lineBreakMode:NSLineBreakByWordWrapping];
#pragma clang diagnostic pop
  return MAX(44,size.height+24);
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"log"];
  if(!cell) cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"log"] autorelease];
  [[cell textLabel] setNumberOfLines:0]; [[cell textLabel] setText:[lines_ objectAtIndex:[path row]]]; [cell setSelectionStyle:UITableViewCellSelectionStyleNone]; return cell;
}
- (void)dealloc { [refreshTimer_ invalidate]; [refreshTimer_ release]; [lines_ release]; [super dealloc]; }
@end
