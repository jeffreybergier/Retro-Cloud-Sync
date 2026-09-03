//
//  DaemonLogView.m
//  RetroCloudSync
//

#import "DaemonLogView.h"

#import "RCServiceController.h"

static const unsigned long long kRCMaximumDisplayedLogSize = 1024 * 1024;

@interface DaemonLogView (Private)
- (NSString *)logContents;
- (void)refreshButtonClicked:(id)sender;
- (void)refreshTimerFired:(NSTimer *)timer;
@end

@implementation DaemonLogView

- (id)initWithFrame:(NSRect)frame;
{
  self = [super initWithFrame:frame];
  if (self != nil) {
    RCServiceController *serviceController;
    NSBox *box;
    NSScrollView *scrollView;
    NSTextView *textView;
    NSTextField *pathLabel;
    NSButton *refreshButton;

    serviceController = [[[RCServiceController alloc] init] autorelease];
    logPath_ = [[serviceController daemonLogPath] copy];

    box = [[[NSBox alloc] initWithFrame:NSMakeRect(16, 48, 448, 256)]
        autorelease];
    [box setTitle:@"Daemon Log"];
    [box setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self addSubview:box];

    scrollView = [[[NSScrollView alloc]
        initWithFrame:NSMakeRect(28, 76, 424, 204)] autorelease];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setAutohidesScrollers:YES];

    textView = [[NSTextView alloc]
        initWithFrame:[[scrollView contentView] bounds]];
    [textView setAutoresizingMask:NSViewWidthSizable];
    [textView setEditable:NO];
    [textView setSelectable:YES];
    [textView setRichText:NO];
    [textView setUsesFontPanel:NO];
    [textView setFont:[NSFont userFixedPitchFontOfSize:
        [NSFont smallSystemFontSize]]];
    [[textView textContainer] setWidthTracksTextView:YES];
    [scrollView setDocumentView:textView];
    [self addSubview:scrollView];
    textView_ = textView;

    pathLabel = [[NSTextField alloc]
        initWithFrame:NSMakeRect(20, 16, 344, 20)];
    [pathLabel setAutoresizingMask:NSViewWidthSizable];
    [pathLabel setBezeled:NO];
    [pathLabel setDrawsBackground:NO];
    [pathLabel setEditable:NO];
    [pathLabel setSelectable:YES];
    [pathLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [pathLabel setStringValue:logPath_];
    [pathLabel setToolTip:logPath_];
    [self addSubview:pathLabel];
    pathLabel_ = pathLabel;

    refreshButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(380, 10, 88, 26)] autorelease];
    [refreshButton setAutoresizingMask:NSViewMinXMargin];
    [refreshButton setTitle:@"Refresh"];
    [refreshButton setBezelStyle:NSRoundedBezelStyle];
    [refreshButton setTarget:self];
    [refreshButton setAction:@selector(refreshButtonClicked:)];
    [self addSubview:refreshButton];

    [self reloadLog];
  }
  return self;
}

- (void)dealloc;
{
  [self stopUpdating];
  [textView_ release];
  [pathLabel_ release];
  [logPath_ release];
  [super dealloc];
}

- (NSString *)logContents;
{
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSDictionary *attributes = [fileManager fileAttributesAtPath:logPath_
                                                  traverseLink:YES];
  unsigned long long fileSize = [[attributes objectForKey:NSFileSize]
      unsignedLongLongValue];
  NSFileHandle *file;
  NSData *data;
  NSString *contents;
  BOOL truncated = fileSize > kRCMaximumDisplayedLogSize;

  if (attributes == nil) {
    return @"No daemon log has been created yet. Start the background service "
            "to create it.";
  }
  file = [NSFileHandle fileHandleForReadingAtPath:logPath_];
  if (file == nil) {
    return @"The daemon log could not be read.";
  }
  if (truncated) {
    [file seekToFileOffset:fileSize - kRCMaximumDisplayedLogSize];
  }
  data = [file readDataToEndOfFile];
  [file closeFile];
  contents = [[[NSString alloc] initWithData:data
                                    encoding:NSUTF8StringEncoding]
      autorelease];
  if (contents == nil) {
    contents = [[[NSString alloc] initWithData:data
                                      encoding:NSISOLatin1StringEncoding]
        autorelease];
  }
  if (contents == nil) {
    return @"The daemon log contains text that cannot be displayed.";
  }
  if (truncated) {
    NSRange firstNewline = [contents rangeOfString:@"\n"];

    if (firstNewline.location != NSNotFound) {
      contents = [contents substringFromIndex:NSMaxRange(firstNewline)];
    }
    contents = [@"[Earlier log entries are not shown.]\n" stringByAppendingString:
        contents];
  }
  return contents;
}

- (void)reloadLog;
{
  NSString *contents = [self logContents];
  NSString *oldContents = [textView_ string];
  NSRange selection;
  BOOL followedEnd;

  if ([oldContents isEqualToString:contents]) return;
  selection = [textView_ selectedRange];
  followedEnd = NSMaxRange(selection) >= [oldContents length];
  [textView_ setString:contents];
  if (followedEnd) {
    [textView_ scrollRangeToVisible:NSMakeRange([contents length], 0)];
  } else if (selection.location <= [contents length]) {
    selection.length = MIN(selection.length,
        [contents length] - selection.location);
    [textView_ setSelectedRange:selection];
    [textView_ scrollRangeToVisible:selection];
  }
}

- (void)startUpdating;
{
  if (refreshTimer_ != nil) return;
  [self reloadLog];
  refreshTimer_ = [[NSTimer scheduledTimerWithTimeInterval:5.0
      target:self selector:@selector(refreshTimerFired:) userInfo:nil
      repeats:YES] retain];
}

- (void)stopUpdating;
{
  [refreshTimer_ invalidate];
  [refreshTimer_ release];
  refreshTimer_ = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer;
{
  (void)timer;
  [self reloadLog];
}

- (void)refreshButtonClicked:(id)sender;
{
  (void)sender;
  [self reloadLog];
}

@end
