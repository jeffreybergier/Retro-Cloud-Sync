#import "RCLogViewController.h"

@implementation RCLogViewController
- (void)loadView {
  textView_=[[UITextView alloc] initWithFrame:CGRectZero];
  [textView_ setEditable:NO];
  [textView_ setFont:[UIFont fontWithName:@"Courier" size:12]];
  [textView_ setAutoresizingMask:UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight];
  [self setView:textView_];
}
- (void)viewDidLoad {
  [super viewDidLoad]; [self setTitle:@"Log"];
  [[self navigationItem] setRightBarButtonItem:[[[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)] autorelease]];
  loader_=[[AICollectionController alloc] initWithTarget:self selector:@selector(logLoaded:) builder:[self class]];
  [self logLoaded:[loader_ buildResultForRequest:[NSDictionary dictionary]]];
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [refreshTimer_ invalidate]; [refreshTimer_ release];
  refreshTimer_=[[NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES] retain];
}
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  [refreshTimer_ invalidate]; [refreshTimer_ release]; refreshTimer_=nil; [loader_ cancel];
}
+ (NSDictionary *)buildList:(NSDictionary *)request {
  (void)request;
  NSFileHandle *file=[NSFileHandle fileHandleForReadingAtPath:@"/var/mobile/Library/Logs/RetroCloudSync/RetroCloudSyncDaemon.log"];
  NSString *tail=nil;
  @try {
    unsigned long long size=[file seekToEndOfFile];
    [file seekToFileOffset:size>1048576 ? size-1048576 : 0];
    NSData *data=[file readDataOfLength:1048576];
    tail=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if(!tail && data) tail=[[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
    if(size>1048576) {
      NSRange newline=[tail rangeOfString:@"\n"];
      if(newline.location!=NSNotFound) tail=[tail substringFromIndex:NSMaxRange(newline)];
      tail=[@"[Earlier log entries are not shown.]\n" stringByAppendingString:tail ?: @""];
    }
  } @catch(NSException *exception) { (void)exception; tail=@"Log unavailable."; }
  @finally { [file closeFile]; }
  return [NSDictionary dictionaryWithObject:tail ?: @"No log yet." forKey:@"text"];
}
- (void)refresh { [loader_ request:[NSDictionary dictionary]]; }
- (void)logLoaded:(NSDictionary *)result {
  NSString *text=[result objectForKey:@"text"];
  if(!text || [[textView_ text] isEqualToString:text]) return;
  CGPoint offset=[textView_ contentOffset];
  NSRange selection=[textView_ selectedRange];
  BOOL followsEnd=![[textView_ text] length] ||
      offset.y+CGRectGetHeight([textView_ bounds]) >= [textView_ contentSize].height-20;
  [textView_ setText:text];
  selection.location=MIN(selection.location,[text length]);
  selection.length=MIN(selection.length,[text length]-selection.location);
  [textView_ setSelectedRange:selection];
  if(followsEnd) [textView_ scrollRangeToVisible:NSMakeRange([text length],0)];
  else [textView_ setContentOffset:offset animated:NO];
}
- (void)viewDidUnload {
  [loader_ invalidate]; [loader_ release]; loader_=nil;
  [textView_ release]; textView_=nil;
  [super viewDidUnload];
}
- (void)dealloc {
  [loader_ invalidate]; [loader_ release];
  [refreshTimer_ invalidate]; [refreshTimer_ release];
  [textView_ release]; [super dealloc];
}
@end
