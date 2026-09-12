//
//  AppDelegate.m
//  RetroCloudSync
//

#import "AppDelegate.h"
#import "PreferencesWindowController.h"

@interface AppDelegate (Private)
- (void)buildMainMenu;
- (void)showWindow;
- (void)showPreferencePane:(id)sender;
@end

@implementation AppDelegate

- (void)dealloc;
{
  [preferencesWindowController_ release];
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
  preferencesWindowController_ =
      [[PreferencesWindowController alloc] init];
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

- (void)buildMainMenu;
{
  NSApplication *application = [NSApplication sharedApplication];
  NSMenu *mainMenu = [[[NSMenu alloc] initWithTitle:@"MainMenu"] autorelease];
  NSMenuItem *applicationItem;
  NSMenu *applicationMenu;
  NSMenuItem *editItem;
  NSMenu *editMenu;
  NSMenuItem *windowItem;
  NSMenu *windowMenu;
  NSArray *paneNames = [NSArray arrayWithObjects:
      @"Status", @"Mail", @"Sync", @"Log", nil];
  unsigned int paneIndex;

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

  editItem = [mainMenu addItemWithTitle:@"Edit"
                                 action:NULL
                          keyEquivalent:@""];
  editMenu = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
  [mainMenu setSubmenu:editMenu forItem:editItem];
  [editMenu addItemWithTitle:@"Cut"
                      action:@selector(cut:)
               keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"Copy"
                      action:@selector(copy:)
               keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Paste"
                      action:@selector(paste:)
               keyEquivalent:@"v"];

  windowItem = [mainMenu addItemWithTitle:@"Window"
                                   action:NULL
                            keyEquivalent:@""];
  windowMenu = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
  [mainMenu setSubmenu:windowMenu forItem:windowItem];
  [application setWindowsMenu:windowMenu];
  for (paneIndex = 0; paneIndex < [paneNames count]; paneIndex++) {
    NSString *paneName = [paneNames objectAtIndex:paneIndex];
    NSMenuItem *paneItem = [windowMenu addItemWithTitle:paneName
        action:@selector(showPreferencePane:)
        keyEquivalent:[NSString stringWithFormat:@"%u", paneIndex + 1]];

    [paneItem setTarget:self];
    [paneItem setRepresentedObject:paneName];
  }
  [windowMenu addItem:[NSMenuItem separatorItem]];
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
  [preferencesWindowController_ showWindow:self];
}

- (void)showPreferencePane:(id)sender;
{
  [preferencesWindowController_ showPreferencePane:[sender representedObject]];
}

@end
