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
- (void)revealButtonClicked:(id)sender;
- (void)refreshTimerFired:(NSTimer *)timer;
@end

@implementation DaemonLogView

- (id)initWithFrame:(NSRect)frame;
{
  self = [super initWithFrame:frame];
  if (self != nil) {
    RCServiceController *serviceController;
    NSScrollView *scrollView;
    NSTextView *textView;
    NSButton *refreshButton;
    NSButton *revealButton;
    float controlsHeight;
    float refreshX;
    const float edgePadding = 8;
    const float controlSpacing = 4;
    const float buttonWidth = 88;
    const float buttonHeight = 26;

    serviceController = [[[RCServiceController alloc] init] autorelease];
    logPath_ = [[serviceController daemonLogPath] copy];
    controlsHeight = buttonHeight + (edgePadding * 2);
    refreshX = NSWidth(frame) - edgePadding - buttonWidth;

    scrollView = [[[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, controlsHeight, NSWidth(frame),
                                 NSHeight(frame) - controlsHeight)] autorelease];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [scrollView setBorderType:NSNoBorder];
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

    revealButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(refreshX - controlSpacing - buttonWidth,
                                 edgePadding, buttonWidth, buttonHeight)]
        autorelease];
    [revealButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [revealButton setTitle:@"Reveal"];
    [revealButton setBezelStyle:NSRoundedBezelStyle];
    [revealButton setTarget:self];
    [revealButton setAction:@selector(revealButtonClicked:)];
    [self addSubview:revealButton];

    refreshButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(refreshX, edgePadding,
                                 buttonWidth, buttonHeight)] autorelease];
    [refreshButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
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

- (void)revealButtonClicked:(id)sender;
{
  (void)sender;
  if (![[NSWorkspace sharedWorkspace] selectFile:logPath_
                           inFileViewerRootedAtPath:@""]) {
    NSRunAlertPanel(@"Retro Cloud Sync",
        @"The daemon log could not be revealed in Finder. "
         "It may not have been created yet.", @"OK", nil, nil);
  }
}

@end
