//
//  PreferencesWindowController.m
//  RetroCloudSync
//

#import "PreferencesWindowController.h"

#import <AltivecCocoa/AIFontAwesome.h>

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
  [daemonToolbarImage_ release];
  [mailToolbarImage_ release];
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

  toolbar = [[NSToolbar alloc] initWithIdentifier:kRCToolbarIdentifier];
  [toolbar setDelegate:self];
  [toolbar setAllowsUserCustomization:NO];
  [toolbar setAutosavesConfiguration:NO];
  daemonToolbarImage_ = [[AIFontAwesome imageForIcon:AIFAServer
      style:AIFontAwesomeStyleSolid iconSize:24.0 canvasSize:32.0
      scale:1.0] retain];
  mailToolbarImage_ = [[AIFontAwesome imageForIcon:AIFAEnvelope
      style:AIFontAwesomeStyleSolid iconSize:24.0 canvasSize:32.0
      scale:1.0] retain];
  if (daemonToolbarImage_ != nil && mailToolbarImage_ != nil) {
    [toolbar setDisplayMode:NSToolbarDisplayModeIconAndLabel];
  } else {
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
    image = daemonToolbarImage_;
  } else {
    image = mailToolbarImage_;
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
