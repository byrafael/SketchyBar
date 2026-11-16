#include "alias_menu.h"
#include <Cocoa/Cocoa.h>
#include <Carbon/Carbon.h>

// Space between the alias and the menu or panel opened under it.
#define ALIAS_MENU_GAP 4.0

static CFTypeRef ax_copy(AXUIElementRef element, CFStringRef attribute) {
  CFTypeRef value = NULL;
  if (AXUIElementCopyAttributeValue(element, attribute, &value)
        != kAXErrorSuccess) {
    return NULL;
  }
  return value;
}

static NSString* ax_string(AXUIElementRef element, CFStringRef attribute) {
  CFTypeRef value = ax_copy(element, attribute);
  if (!value) return nil;
  if (CFGetTypeID(value) != CFStringGetTypeID()) {
    CFRelease(value);
    return nil;
  }
  return [(NSString*)value autorelease];
}

static long ax_long(AXUIElementRef element, CFStringRef attribute, long fallback) {
  CFTypeRef value = ax_copy(element, attribute);
  if (!value) return fallback;
  long result = fallback;
  if (CFGetTypeID(value) == CFNumberGetTypeID()) {
    CFNumberGetValue(value, kCFNumberLongType, &result);
  } else if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
    result = CFBooleanGetValue(value);
  }
  CFRelease(value);
  return result;
}

static CGRect ax_frame(AXUIElementRef element) {
  CGPoint position = CGPointZero;
  CGSize size = CGSizeZero;
  CFTypeRef value = ax_copy(element, kAXPositionAttribute);
  if (value) {
    AXValueGetValue(value, kAXValueTypeCGPoint, &position);
    CFRelease(value);
  }
  value = ax_copy(element, kAXSizeAttribute);
  if (value) {
    AXValueGetValue(value, kAXValueTypeCGSize, &size);
    CFRelease(value);
  }
  return (CGRect){ position, size };
}

// The AXMenu among `element`'s children, retained, or NULL.
static AXUIElementRef ax_copy_menu_child(AXUIElementRef element) {
  CFArrayRef children = ax_copy(element, kAXChildrenAttribute);
  if (!children) return NULL;
  AXUIElementRef menu = NULL;
  for (CFIndex i = 0; i < CFArrayGetCount(children) && !menu; i++) {
    AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
    NSString* role = ax_string(child, kAXRoleAttribute);
    if ([role isEqualToString:(NSString*)kAXMenuRole]) menu = CFRetain(child);
  }
  CFRelease(children);
  return menu;
}

static CGRect display_bounds_containing(CGRect rect) {
  CGPoint center = { CGRectGetMidX(rect), CGRectGetMidY(rect) };
  CGDirectDisplayID display = CGMainDisplayID();
  uint32_t count = 0;
  CGGetDisplaysWithPoint(center, 1, &display, &count);
  return CGDisplayBounds(count ? display : CGMainDisplayID());
}

// Top-left corner for something `width` wide opened under `anchor`, centred on
// it and kept on its display.
static CGPoint origin_under(CGRect anchor, CGFloat width) {
  CGRect screen = display_bounds_containing(anchor);
  CGFloat x = CGRectGetMidX(anchor) - width / 2.0;
  x = fmin(x, CGRectGetMaxX(screen) - width - ALIAS_MENU_GAP);
  x = fmax(x, CGRectGetMinX(screen) + ALIAS_MENU_GAP);
  return (CGPoint){ x, CGRectGetMaxY(anchor) + ALIAS_MENU_GAP };
}

// AXMenuItemCmdModifiers: Command is implied unless bit 3 is set.
static NSEventModifierFlags modifier_flags(long ax_modifiers) {
  NSEventModifierFlags flags = 0;
  if (!(ax_modifiers & (1 << 3))) flags |= NSEventModifierFlagCommand;
  if (ax_modifiers & (1 << 0)) flags |= NSEventModifierFlagShift;
  if (ax_modifiers & (1 << 1)) flags |= NSEventModifierFlagOption;
  if (ax_modifiers & (1 << 2)) flags |= NSEventModifierFlagControl;
  return flags;
}

// Fills an NSMenu from an app's AXMenu when it is about to open, so large
// submenus are only read if they are shown.
@interface SBAliasMenuSource : NSObject <NSMenuDelegate> {
 @public
  AXUIElementRef ax_menu;
  NSMutableArray* sources;
}
@end

static AXUIElementRef g_chosen = NULL;

@implementation SBAliasMenuSource

- (void)dealloc {
  if (ax_menu) CFRelease(ax_menu);
  [super dealloc];
}

- (void)choose:(NSMenuItem*)item {
  if (g_chosen) CFRelease(g_chosen);
  g_chosen = (AXUIElementRef)CFRetain([item representedObject]);
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  if ([menu numberOfItems] > 0) return;
  CFArrayRef children = ax_copy(ax_menu, kAXChildrenAttribute);
  if (!children) return;

  for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
    AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
    NSString* title = ax_string(child, kAXTitleAttribute) ?: @"";
    AXUIElementRef submenu = ax_copy_menu_child(child);

    if (title.length == 0 && !submenu) {
      [menu addItem:[NSMenuItem separatorItem]];
      continue;
    }

    NSString* key = @"";
    NSString* cmd_char = ax_string(child, kAXMenuItemCmdCharAttribute);
    if (cmd_char.length > 0) key = [cmd_char lowercaseString];

    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:nil
                                           keyEquivalent:key];
    if (key.length > 0) {
      item.keyEquivalentModifierMask = modifier_flags(
        ax_long(child, kAXMenuItemCmdModifiersAttribute, 0));
    }
    item.enabled = ax_long(child, kAXEnabledAttribute, 1) != 0;
    if (ax_string(child, kAXMenuItemMarkCharAttribute).length > 0) {
      item.state = NSControlStateValueOn;
    }

    if (submenu) {
      SBAliasMenuSource* source = [[SBAliasMenuSource alloc] init];
      source->ax_menu = submenu;
      source->sources = sources;
      [sources addObject:source];
      NSMenu* child_menu = [[NSMenu alloc] initWithTitle:title];
      child_menu.autoenablesItems = NO;
      child_menu.delegate = source;
      item.submenu = child_menu;
      [child_menu release];
      [source release];
    } else {
      item.representedObject = (id)child;
      item.target = self;
      item.action = @selector(choose:);
    }
    [menu addItem:item];
    [item release];
  }
  CFRelease(children);
}

@end

// Status bar apps that are not Cocoa apps (this one runs a Carbon event loop)
// need NSApplication loaded before they can show a menu.
static void load_cocoa(void) {
  static bool loaded = false;
  if (loaded) return;
  loaded = true;
  NSApplicationLoad();
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

bool alias_menu_show(AXUIElementRef ax_menu, CGRect anchor) {
  CFArrayRef children = ax_copy(ax_menu, kAXChildrenAttribute);
  CFIndex count = children ? CFArrayGetCount(children) : 0;
  if (children) CFRelease(children);
  if (count == 0) return false;

  load_cocoa();
  CFRetain(ax_menu);

  // The click that got here is still being handled, and the menu runs its
  // own event loop until it closes: open it once the click is done.
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
    @autoreleasepool {
      NSMutableArray* sources = [NSMutableArray array];
      SBAliasMenuSource* source = [[SBAliasMenuSource alloc] init];
      source->ax_menu = ax_menu;
      source->sources = sources;
      [sources addObject:source];
      [source release];

      NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
      menu.autoenablesItems = NO;
      menu.delegate = source;
      [source menuNeedsUpdate:menu];

      CGPoint origin = origin_under(anchor, menu.size.width);
      CGFloat primary_height = CGDisplayBounds(CGMainDisplayID()).size.height;
      [menu popUpMenuPositioningItem:nil
                          atLocation:NSMakePoint(origin.x,
                                                 primary_height - origin.y)
                              inView:nil];
      [menu release];

      if (g_chosen) {
        AXUIElementRef chosen = g_chosen;
        g_chosen = NULL;
        // An item whose action opens a dialog may not answer until it
        // closes; the action still runs.
        AXUIElementSetMessagingTimeout(chosen, 0.5);
        AXUIElementPerformAction(chosen, kAXPressAction);
        CFRelease(chosen);
      }
    }
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
  return true;
}

static CFArrayRef copy_window_numbers(pid_t pid) {
  CFMutableArrayRef numbers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
  CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,
                                                  kCGNullWindowID                );
  if (!windows) return numbers;
  for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
    CFDictionaryRef window = CFArrayGetValueAtIndex(windows, i);
    CFNumberRef owner = CFDictionaryGetValue(window, kCGWindowOwnerPID);
    CFNumberRef number = CFDictionaryGetValue(window, kCGWindowNumber);
    pid_t owner_pid = 0;
    if (!owner || !number) continue;
    CFNumberGetValue(owner, kCFNumberIntType, &owner_pid);
    if (owner_pid == pid) CFArrayAppendValue(numbers, number);
  }
  CFRelease(windows);
  return numbers;
}

// The frame of the first on-screen window of `pid` missing from `before`
// whose top edge is right under `item`, as a dropdown from it would be.
static bool find_opened_window(pid_t pid, CFArrayRef before, CGRect item, CGRect* frame) {
  CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,
                                                  kCGNullWindowID                );
  if (!windows) return false;
  bool found = false;
  for (CFIndex i = 0; i < CFArrayGetCount(windows) && !found; i++) {
    CFDictionaryRef window = CFArrayGetValueAtIndex(windows, i);
    CFNumberRef owner = CFDictionaryGetValue(window, kCGWindowOwnerPID);
    CFNumberRef number = CFDictionaryGetValue(window, kCGWindowNumber);
    CFDictionaryRef bounds = CFDictionaryGetValue(window, kCGWindowBounds);
    pid_t owner_pid = 0;
    if (!owner || !number || !bounds) continue;
    CFNumberGetValue(owner, kCFNumberIntType, &owner_pid);
    if (owner_pid != pid) continue;
    if (CFArrayContainsValue(before, CFRangeMake(0, CFArrayGetCount(before)), number)) {
      continue;
    }
    CGRect rect;
    if (!CGRectMakeWithDictionaryRepresentation(bounds, &rect)) continue;
    if (fabs(CGRectGetMinY(rect) - CGRectGetMaxY(item)) > 16.0) continue;
    *frame = rect;
    found = true;
  }
  CFRelease(windows);
  return found;
}

static bool move_window(pid_t pid, CGRect frame, CGPoint origin) {
  AXUIElementRef app = AXUIElementCreateApplication(pid);
  if (!app) return false;
  AXUIElementSetMessagingTimeout(app, 0.2);
  bool moved = false;
  CFArrayRef windows = ax_copy(app, kAXWindowsAttribute);
  for (CFIndex i = 0; windows && i < CFArrayGetCount(windows) && !moved; i++) {
    AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
    CGRect ax = ax_frame(window);
    if (fabs(ax.origin.x - frame.origin.x) > 1.0
        || fabs(ax.origin.y - frame.origin.y) > 1.0
        || fabs(ax.size.width - frame.size.width) > 1.0) {
      continue;
    }
    AXValueRef value = AXValueCreate(kAXValueTypeCGPoint, &origin);
    moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute, value)
            == kAXErrorSuccess;
    CFRelease(value);
  }
  if (windows) CFRelease(windows);
  CFRelease(app);
  return moved;
}

static void follow(pid_t pid, CFArrayRef before, CGRect item, CGRect anchor, int tries) {
  CGRect frame;
  if (find_opened_window(pid, before, item, &frame)) {
    move_window(pid, frame, origin_under(anchor, frame.size.width));
  } else if (tries > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(),
                   ^{ follow(pid, before, item, anchor, tries - 1); });
    return;
  }
  CFRelease(before);
}

void alias_menu_follow_window(pid_t pid, CGRect item, CGRect anchor) {
  // Apps take a moment to open the window after the press: watch for a
  // second.
  follow(pid, copy_window_numbers(pid), item, anchor, 20);
}
