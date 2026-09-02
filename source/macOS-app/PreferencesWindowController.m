//
//  PreferencesWindowController.m
//  RetroCloudSync
//

#import "PreferencesWindowController.h"

#import "DaemonStatusView.h"

@implementation PreferencesWindowController

- (id)init;
{
  return [super initWithWindowNibName:@"ignored"];
}

- (void)dealloc;
{
  [[self window] setDelegate:nil];
  [daemonStatusView_ stopUpdating];
  [daemonStatusView_ release];
  [super dealloc];
}

- (void)loadWindow;
{
  unsigned int styleMask;
  NSRect frame;
  NSWindow *window;
  DaemonStatusView *daemonStatusView;

  frame = NSMakeRect(0, 0, 480, 320);
  styleMask = NSTitledWindowMask | NSClosableWindowMask |
              NSMiniaturizableWindowMask | NSResizableWindowMask;
  window = [[[NSWindow alloc] initWithContentRect:frame
                                        styleMask:styleMask
                                          backing:NSBackingStoreBuffered
                                            defer:NO] autorelease];
  [window setReleasedWhenClosed:NO];
  [window setDelegate:self];
  [window setTitle:@"Retro Cloud Sync"];
  [window setBackgroundColor:
      [NSColor colorWithCalibratedRed:0.82 green:0.91 blue:1.0 alpha:1.0]];

  daemonStatusView = [[[DaemonStatusView alloc]
      initWithFrame:[[window contentView] bounds]] autorelease];
  [daemonStatusView setAutoresizingMask:NSViewWidthSizable |
                                        NSViewHeightSizable];
  [[window contentView] addSubview:daemonStatusView];
  daemonStatusView_ = [daemonStatusView retain];

  [window center];
  [self setWindow:window];
}

- (void)showWindow:(id)sender;
{
  [daemonStatusView_ startUpdating];
  [super showWindow:sender];
}

- (void)windowWillClose:(NSNotification *)notification;
{
  (void)notification;
  [daemonStatusView_ stopUpdating];
}

@end
