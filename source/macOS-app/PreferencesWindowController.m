//
//  PreferencesWindowController.m
//  RetroCloudSync
//

#import "PreferencesWindowController.h"

#import "DaemonStatusView.h"
#import "MailServerView.h"

static NSString * const kRCDaemonToolbarItem = @"Daemon";
static NSString * const kRCMailToolbarItem = @"Mail";
static NSString * const kRCToolbarIdentifier = @"RetroCloudSyncPreferences";

@interface PreferencesWindowController (Private)
- (void)selectPreferencePane:(id)sender;
- (void)showView:(NSView *)view;
@end

@implementation PreferencesWindowController

- (id)init;
{
  return [super initWithWindowNibName:@"ignored"];
}

- (void)dealloc;
{
  NSEnumerator *itemEnumerator = [[toolbar_ items] objectEnumerator];
  NSToolbarItem *item;

  while ((item = [itemEnumerator nextObject]) != nil) {
    [item setTarget:nil];
  }
  [toolbar_ setDelegate:nil];
  [[self window] setDelegate:nil];
  [daemonStatusView_ stopUpdating];
  visibleView_ = nil;
  [daemonStatusView_ release];
  [mailServerView_ release];
  [toolbar_ release];
  [super dealloc];
}

- (void)loadWindow;
{
  unsigned int styleMask;
  NSRect frame;
  NSWindow *window;
  DaemonStatusView *daemonStatusView;
  MailServerView *mailServerView;
  NSToolbar *toolbar;
  NSImage *daemonImage;
  NSImage *mailImage;

  frame = NSMakeRect(0, 0, 480, 320);
  styleMask = NSTitledWindowMask | NSClosableWindowMask |
              NSMiniaturizableWindowMask | NSResizableWindowMask;
  window = [[NSWindow alloc] initWithContentRect:frame
                                       styleMask:styleMask
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
  [window setReleasedWhenClosed:NO];
  [window setDelegate:self];
  [window setTitle:@"Retro Cloud Sync"];
  [window setBackgroundColor:
      [NSColor colorWithCalibratedRed:0.82 green:0.91 blue:1.0 alpha:1.0]];

  toolbar = [[NSToolbar alloc] initWithIdentifier:kRCToolbarIdentifier];
  [toolbar setDelegate:self];
  [toolbar setAllowsUserCustomization:NO];
  [toolbar setAutosavesConfiguration:NO];
  daemonImage = [NSImage imageNamed:@"NSPreferencesGeneral"];
  mailImage = [NSImage imageNamed:@"NSNetwork"];
  if (daemonImage != nil && mailImage != nil) {
    /* Leopard supplies the standard images used by preference toolbars. */
    [toolbar setDisplayMode:NSToolbarDisplayModeIconAndLabel];
  } else {
    /* Tiger has selectable toolbars but not the preference image set. */
    [toolbar setDisplayMode:NSToolbarDisplayModeLabelOnly];
  }
  [toolbar setSizeMode:NSToolbarSizeModeRegular];
  [window setToolbar:toolbar];
  toolbar_ = toolbar;

  daemonStatusView = [[DaemonStatusView alloc]
      initWithFrame:[[window contentView] bounds]];
  [daemonStatusView setAutoresizingMask:NSViewWidthSizable |
                                        NSViewHeightSizable];
  daemonStatusView_ = daemonStatusView;

  mailServerView = [[MailServerView alloc]
      initWithFrame:[[window contentView] bounds]];
  [mailServerView setAutoresizingMask:NSViewWidthSizable |
                                      NSViewHeightSizable];
  mailServerView_ = mailServerView;

  [self setWindow:window];
  [toolbar setSelectedItemIdentifier:kRCDaemonToolbarItem];
  [self showView:daemonStatusView_];

  [window center];
  [window release];
}

- (void)showWindow:(id)sender;
{
  if (visibleView_ == daemonStatusView_) {
    [daemonStatusView_ startUpdating];
  }
  [super showWindow:sender];
}

- (void)windowWillClose:(NSNotification *)notification;
{
  (void)notification;
  [daemonStatusView_ stopUpdating];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar;
{
  (void)toolbar;
  return [NSArray arrayWithObjects:kRCDaemonToolbarItem,
                                   kRCMailToolbarItem, nil];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar;
{
  return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSArray *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar;
{
  return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSString *)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag;
{
  NSToolbarItem *item;
  NSImage *image = nil;

  (void)toolbar;
  (void)flag;
  if (![itemIdentifier isEqualToString:kRCDaemonToolbarItem] &&
      ![itemIdentifier isEqualToString:kRCMailToolbarItem]) {
    return nil;
  }
  item = [[[NSToolbarItem alloc]
      initWithItemIdentifier:itemIdentifier] autorelease];
  [item setLabel:itemIdentifier];
  [item setPaletteLabel:itemIdentifier];
  [item setToolTip:[NSString stringWithFormat:@"Show %@ settings",
                                               itemIdentifier]];
  [item setTarget:self];
  [item setAction:@selector(selectPreferencePane:)];
  if ([itemIdentifier isEqualToString:kRCDaemonToolbarItem]) {
    image = [NSImage imageNamed:@"NSPreferencesGeneral"];
  } else {
    image = [NSImage imageNamed:@"NSNetwork"];
  }
  if (image != nil) {
    [item setImage:image];
  }
  return item;
}

- (void)selectPreferencePane:(id)sender;
{
  NSString *identifier = [sender itemIdentifier];

  if ([identifier isEqualToString:kRCMailToolbarItem]) {
    [mailServerView_ reloadSettings];
    [self showView:mailServerView_];
  } else {
    [self showView:daemonStatusView_];
  }
  [toolbar_ setSelectedItemIdentifier:identifier];
}

- (void)showView:(NSView *)view;
{
  if (visibleView_ == view) {
    return;
  }
  [visibleView_ removeFromSuperview];
  [view setFrame:[[[self window] contentView] bounds]];
  [[[self window] contentView] addSubview:view];
  visibleView_ = view;
  if (view == daemonStatusView_) {
    [daemonStatusView_ startUpdating];
  } else {
    [daemonStatusView_ stopUpdating];
  }
}

@end
