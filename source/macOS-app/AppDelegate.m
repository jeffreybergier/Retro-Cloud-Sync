//
//  AppDelegate.m
//  RetroCloudSync
//

#import "AppDelegate.h"

@interface AppDelegate (Private)
- (void)buildMainMenu;
- (void)showWindow;
@end

@implementation AppDelegate

- (void)dealloc;
{
  [window_ setDelegate:nil];
  [window_ release];
  [super dealloc];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification;
{
  (void)notification;
  [self buildMainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
{
  (void)notification;
  [self showWindow];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application
                     hasVisibleWindows:(BOOL)hasVisibleWindows;
{
  (void)application;
  (void)hasVisibleWindows;
  [self showWindow];
  return YES;
}

- (void)windowWillClose:(NSNotification *)notification;
{
  if ([notification object] == window_) {
    [window_ setDelegate:nil];
    [window_ autorelease];
    window_ = nil;
  }
}

- (void)buildMainMenu;
{
  NSApplication *application = [NSApplication sharedApplication];
  NSMenu *mainMenu = [[[NSMenu alloc] initWithTitle:@"MainMenu"] autorelease];
  NSMenuItem *applicationItem;
  NSMenu *applicationMenu;
  NSMenuItem *windowItem;
  NSMenu *windowMenu;

  applicationItem = [mainMenu addItemWithTitle:@""
                                        action:NULL
                                 keyEquivalent:@""];
  applicationMenu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
  [mainMenu setSubmenu:applicationMenu forItem:applicationItem];

  if ([application respondsToSelector:@selector(setAppleMenu:)]) {
    [application performSelector:@selector(setAppleMenu:)
                      withObject:applicationMenu];
  }

  [applicationMenu addItemWithTitle:@"About Retro Cloud Sync"
                             action:@selector(orderFrontStandardAboutPanel:)
                      keyEquivalent:@""];
  [applicationMenu addItem:[NSMenuItem separatorItem]];
  [applicationMenu addItemWithTitle:@"Hide Retro Cloud Sync"
                             action:@selector(hide:)
                      keyEquivalent:@"h"];
  [applicationMenu addItem:[NSMenuItem separatorItem]];
  [applicationMenu addItemWithTitle:@"Quit Retro Cloud Sync"
                             action:@selector(terminate:)
                      keyEquivalent:@"q"];

  windowItem = [mainMenu addItemWithTitle:@"Window"
                                   action:NULL
                            keyEquivalent:@""];
  windowMenu = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
  [mainMenu setSubmenu:windowMenu forItem:windowItem];
  [application setWindowsMenu:windowMenu];
  [windowMenu addItemWithTitle:@"Minimize"
                        action:@selector(performMiniaturize:)
                 keyEquivalent:@"m"];
  [windowMenu addItemWithTitle:@"Bring All to Front"
                        action:@selector(arrangeInFront:)
                 keyEquivalent:@""];

  [application setMainMenu:mainMenu];
}

- (void)showWindow;
{
  unsigned int styleMask;
  NSRect frame;

  if (window_ != nil) {
    [window_ makeKeyAndOrderFront:self];
    return;
  }

  frame = NSMakeRect(0, 0, 480, 320);
  styleMask = NSTitledWindowMask | NSClosableWindowMask |
              NSMiniaturizableWindowMask | NSResizableWindowMask;
  window_ = [[NSWindow alloc] initWithContentRect:frame
                                       styleMask:styleMask
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
  [window_ setReleasedWhenClosed:NO];
  [window_ setDelegate:self];
  [window_ setTitle:@"Retro Cloud Sync"];
  [window_ setBackgroundColor:
      [NSColor colorWithCalibratedRed:0.82 green:0.91 blue:1.0 alpha:1.0]];
  [window_ center];
  [window_ makeKeyAndOrderFront:self];
}

@end
