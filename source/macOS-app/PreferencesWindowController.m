//
//  PreferencesWindowController.m
//  RetroCloudSync
//

#import "PreferencesWindowController.h"

#import <AltivecCocoa/AIFontAwesome.h>

#import "DaemonStatusView.h"
#import "MailServerView.h"
#import "ContactsView.h"
#import "XPAppKit.h"
#import "DaemonLogView.h"

static NSString * const kRCDaemonToolbarItem = @"Status";
static NSString * const kRCMailToolbarItem = @"Mail";
static NSString * const kRCSyncToolbarItem = @"Sync";
static NSString * const kRCLogToolbarItem = @"Log";
static NSString * const kRCToolbarIdentifier = @"RetroCloudSyncPreferences";
static NSString * const kRCWindowFrameAutosaveName = @"RetroCloudSyncPreferences";

@interface PreferencesWindowController (Private)
- (void)selectPreferencePane:(id)sender;
- (void)showView:(NSView *)view;
- (void)rebuildToolbarImagesForWindow:(NSWindow *)window;
- (NSImage *)imageForToolbarIdentifier:(NSString *)identifier;
@end

@implementation PreferencesWindowController

- (id)init;
{
  self = [super initWithWindowNibName:@"ignored"];
  if (self != nil) {
    [self setShouldCascadeWindows:NO];
  }
  return self;
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
  [daemonLogView_ stopUpdating];
  visibleView_ = nil;
  [daemonStatusView_ release];
  [mailServerView_ release];
  [contactsView_ release];
  [daemonLogView_ release];
  [daemonToolbarImage_ release];
  [mailToolbarImage_ release];
  [contactsToolbarImage_ release];
  [logToolbarImage_ release];
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
  ContactsView *contactsView;
  DaemonLogView *daemonLogView;
  NSToolbar *toolbar;

  frame = NSMakeRect(0, 0, 480, 480);
  styleMask = NSTitledWindowMask | NSClosableWindowMask |
              NSMiniaturizableWindowMask | NSResizableWindowMask;
  window = [[NSWindow alloc] initWithContentRect:frame
                                       styleMask:styleMask
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
  [window setReleasedWhenClosed:NO];
  [window setContentMinSize:NSMakeSize(480, 480)];
  [window setDelegate:self];
  [window setTitle:@"Retro Cloud Sync"];

  toolbar = [[NSToolbar alloc] initWithIdentifier:kRCToolbarIdentifier];
  [toolbar setDelegate:self];
  [toolbar setAllowsUserCustomization:NO];
  [toolbar setAutosavesConfiguration:NO];
  [self rebuildToolbarImagesForWindow:window];
  if (daemonToolbarImage_ != nil && mailToolbarImage_ != nil &&
      contactsToolbarImage_ != nil && logToolbarImage_ != nil) {
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

  contactsView = [[ContactsView alloc]
      initWithFrame:[[window contentView] bounds]];
  [contactsView setAutoresizingMask:NSViewWidthSizable |
                                    NSViewHeightSizable];
  contactsView_ = contactsView;

  daemonLogView = [[DaemonLogView alloc]
      initWithFrame:[[window contentView] bounds]];
  [daemonLogView setAutoresizingMask:NSViewWidthSizable |
                                     NSViewHeightSizable];
  daemonLogView_ = daemonLogView;

  [self setWindow:window];
  [toolbar setSelectedItemIdentifier:kRCDaemonToolbarItem];
  [self showView:daemonStatusView_];

  if (![window setFrameUsingName:kRCWindowFrameAutosaveName]) {
    [window center];
  }
  [window setFrameAutosaveName:kRCWindowFrameAutosaveName];
  [window release];
}

- (void)showWindow:(id)sender;
{
  [super showWindow:sender];
  if (visibleView_ == daemonStatusView_) {
    [daemonStatusView_ startUpdating];
  } else if (visibleView_ == daemonLogView_) {
    [daemonLogView_ startUpdating];
  }
}

- (void)windowWillClose:(NSNotification *)notification;
{
  (void)notification;
  [[self window] makeFirstResponder:nil];
  [daemonStatusView_ stopUpdating];
  [daemonLogView_ stopUpdating];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar;
{
  (void)toolbar;
  return [NSArray arrayWithObjects:kRCDaemonToolbarItem,
                                   kRCMailToolbarItem,
                                   kRCSyncToolbarItem,
                                   kRCLogToolbarItem, nil];
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
      ![itemIdentifier isEqualToString:kRCMailToolbarItem] &&
      ![itemIdentifier isEqualToString:kRCSyncToolbarItem] &&
      ![itemIdentifier isEqualToString:kRCLogToolbarItem]) {
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
  image = [self imageForToolbarIdentifier:itemIdentifier];
  if (image != nil) {
    [item setImage:image];
  }
  return item;
}

- (NSImage *)imageForToolbarIdentifier:(NSString *)identifier;
{
  if([identifier isEqual:kRCDaemonToolbarItem]) return daemonToolbarImage_;
  if([identifier isEqual:kRCSyncToolbarItem]) return contactsToolbarImage_;
  if([identifier isEqual:kRCLogToolbarItem]) return logToolbarImage_;
  return mailToolbarImage_;
}
- (void)rebuildToolbarImagesForWindow:(NSWindow *)window;
{
  CGFloat scale=[window XP_backingScaleFactor]; if(scale<1.0) scale=1.0;
  NSImage **images[]={&daemonToolbarImage_,&mailToolbarImage_,&contactsToolbarImage_,&logToolbarImage_};
  AIFontAwesomeIcon icons[]={AIFAGauge,AIFAEnvelope,AIFAAddressBook,AIFAFileLines};
  for(unsigned int n=0;n<4;n++) {
    NSImage *image=[[AIFontAwesome imageForIcon:icons[n] style:AIFontAwesomeStyleSolid
        iconSize:24.0 canvasSize:32.0 scale:scale] retain];
    [*images[n] release]; *images[n]=image;
  }
  NSEnumerator *items=[[toolbar_ items] objectEnumerator]; NSToolbarItem *item;
  while((item=[items nextObject]))
    [item setImage:[self imageForToolbarIdentifier:[item itemIdentifier]]];
}
- (void)windowDidChangeBackingProperties:(NSNotification *)notification;
{
  [self rebuildToolbarImagesForWindow:[notification object]];
}
- (void)windowDidChangeScreen:(NSNotification *)notification;
{
  [self rebuildToolbarImagesForWindow:[notification object]];
}

- (void)selectPreferencePane:(id)sender;
{
  [self showPreferencePane:[sender itemIdentifier]];
}

- (void)showPreferencePane:(NSString *)identifier;
{
  if (![[self window] makeFirstResponder:nil]) return;
  if ([identifier isEqualToString:kRCMailToolbarItem]) {
    [mailServerView_ reloadSettings];
    [self showView:mailServerView_];
  } else if ([identifier isEqualToString:kRCSyncToolbarItem]) {
    [contactsView_ reloadSettings];
    [self showView:contactsView_];
  } else if ([identifier isEqualToString:kRCLogToolbarItem]) {
    [daemonLogView_ reloadLog];
    [self showView:daemonLogView_];
  } else {
    [self showView:daemonStatusView_];
  }
  [toolbar_ setSelectedItemIdentifier:identifier];
  [self showWindow:self];
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
  if (view == daemonLogView_) {
    [daemonLogView_ startUpdating];
  } else {
    [daemonLogView_ stopUpdating];
  }
}

@end
