#include "alias.h"
#include "misc/helpers.h"
#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include "workspace.h"
#include "alias_menu.h"

struct menu_item {
  char* owner;
  char* name;
  pid_t pid;

  float x_pos;
  uint32_t wid;
  uint64_t layer;

  CGRect bounds;
};

void menu_item_init(struct menu_item* menu_item) {
  memset(menu_item, 0, sizeof(struct menu_item)); 
  menu_item->x_pos = g_nirvana.x;
}

void menu_item_clear(struct menu_item* menu_item) {
  if (menu_item->name) free(menu_item->name);
  if (menu_item->owner) free(menu_item->owner);
  memset(menu_item, 0, sizeof(struct menu_item)); 
}

struct menu_item_list {
  struct menu_item* menu_items;
  uint32_t menu_item_count;
};

void menu_item_list_init(struct menu_item_list* menu_item_list, uint32_t menu_item_count) {
  menu_item_list->menu_items = malloc(sizeof(struct menu_item)*menu_item_count);
  menu_item_list->menu_item_count = menu_item_count;
  for (int i = 0; i < menu_item_count; i++) {
    menu_item_init(menu_item_list->menu_items + i);
  }
}

void menu_item_list_sort(struct menu_item_list* menu_item_list) {
  struct menu_item tmp;
  for (int i = 0; i < menu_item_list->menu_item_count; i++) {
    float highest_value = g_nirvana.x;
    uint32_t highest_value_index = 0;
    for (int j = i; j < menu_item_list->menu_item_count; j++) {
      if (menu_item_list->menu_items[j].x_pos > highest_value) {
        highest_value = menu_item_list->menu_items[j].x_pos;
        highest_value_index = j;
      }
    }
    if (i != highest_value_index) {
      tmp = menu_item_list->menu_items[i];
      menu_item_list->menu_items[i]
                            = menu_item_list->menu_items[highest_value_index];
      menu_item_list->menu_items[highest_value_index] = tmp;
    }
  }
}

void menu_item_list_clear(struct menu_item_list* menu_item_list) {
  if (menu_item_list->menu_items) {
    for (int i = 0; i < menu_item_list->menu_item_count; i++) {
      menu_item_clear(menu_item_list->menu_items + i);
    }
    free(menu_item_list->menu_items);
  }
  memset(menu_item_list, 0, sizeof(struct menu_item_list)); 
}

struct menu_item_list get_menu_item_list() {
  CFArrayRef window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll,
                                                      kCGNullWindowID        );
  int window_count = CFArrayGetCount(window_list);

  struct menu_item_list menu_item_list;
  menu_item_list_init(&menu_item_list, window_count);

  int item_count = 0;
  for (int i = 0; i < window_count; ++i) {
    CFDictionaryRef dictionary = CFArrayGetValueAtIndex(window_list, i);
    if (!dictionary) continue;

    CFStringRef owner_ref = CFDictionaryGetValue(dictionary,
                                                 kCGWindowOwnerName);

    CFNumberRef owner_pid_ref = CFDictionaryGetValue(dictionary,
                                                     kCGWindowOwnerPID);

    CFStringRef name_ref = CFDictionaryGetValue(dictionary, kCGWindowName);
    CFNumberRef layer_ref = CFDictionaryGetValue(dictionary, kCGWindowLayer);
    CFDictionaryRef bounds_ref = CFDictionaryGetValue(dictionary,
                                                      kCGWindowBounds);
    CFNumberRef window_id_ref = CFDictionaryGetValue(dictionary,
                                                     kCGWindowNumber);


    if (!name_ref || !owner_ref || !owner_pid_ref || !layer_ref || !bounds_ref
        || !window_id_ref)
      continue;

    long long int layer = 0;
    CFNumberGetValue(layer_ref, CFNumberGetType(layer_ref), &layer);
    uint64_t owner_pid = 0;
    CFNumberGetValue(owner_pid_ref,
                     CFNumberGetType(owner_pid_ref),
                     &owner_pid                     );

    if (layer != MENUBAR_LAYER) continue;
    CGRect bounds = CGRectNull;
    if (!CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds)) continue;
    char* owner_copy = cfstring_copy(owner_ref);
    if (string_equals(owner_copy, "Window Server")) {
      free(owner_copy);
      continue;
    }

    uint64_t wid;
    CFNumberGetValue(window_id_ref,
                     CFNumberGetType(window_id_ref),
                     &wid                           );
    
    struct menu_item* menu_item = menu_item_list.menu_items + item_count++;
    menu_item->owner = owner_copy;
    menu_item->name = cfstring_copy(name_ref);
    menu_item->pid = (pid_t)owner_pid;
    menu_item->x_pos = bounds.origin.x;
    menu_item->wid = wid;
    menu_item->layer = layer;
    menu_item->bounds = bounds;
  }

  menu_item_list.menu_item_count = item_count;
  menu_item_list_sort(&menu_item_list);
  CFRelease(window_list);
  return menu_item_list;
}

void print_all_menu_items(FILE* rsp) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 110000
  if (__builtin_available(macOS 11.0, *)) {
    if (!CGRequestScreenCaptureAccess()) {
      respond(rsp, "[!] Query (default_menu_items): Screen Recording "
                   "Permissions not given. Restart SketchyBar after granting "
                   "permissions.\n");
      return;
    }
  }

#endif
  struct menu_item_list menu_item_list = get_menu_item_list();
  if (menu_item_list.menu_item_count == 0) {
    // macOS 26 and later: status items have no windows of their own.
    workspace_print_status_items(rsp);
  }
  if (menu_item_list.menu_item_count > 0) {
    fprintf(rsp, "[\n");
    int counter = 0;
    for (int i = 0; i < menu_item_list.menu_item_count; i++) {
      struct menu_item* item = menu_item_list.menu_items + i;
      if (counter++ > 0) {
        fprintf(rsp, ", \n");
      }
      fprintf(rsp, "\t\"%s,%s(%d)\"", item->owner,
                                      item->name,
                                      counter     );
    }
    fprintf(rsp, "\n]\n");
  }
  menu_item_list_clear(&menu_item_list);
}

void alias_get_permission(struct alias* alias) { 
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 110000 
  if (__builtin_available(macOS 11.0, *)) {
    alias->permission = CGRequestScreenCaptureAccess();
  }
#else
  if(__builtin_available(macos 10.15, *)) {
    CGImageRef img = CGWindowListCreateImage(CGRectMake(0, 0, 1, 1),
                                             kCGWindowListOptionOnScreenOnly,
                                             kCGNullWindowID,
                                             kCGWindowImageDefault           );

    CFRelease(img);
  }
#endif
}

void alias_init(struct alias* alias) {
  alias->name = NULL;
  alias->owner = NULL;
  alias->color_override = false;
  color_init(&alias->color, 0xffff0000);
  alias->update_frequency = 1;
  alias->counter = 0;
  alias->pid = 0;
  alias->status_item = false;
  alias->menubar = 0;
  alias->item_frame = CGRectNull;
  alias->menubar_frame = CGRectNull;
  alias->trim = false;
  alias->trim_left = -1;
  alias->trim_right = -1;
  alias->trim_size = CGSizeZero;

  window_init(&alias->window);
  image_init(&alias->image);
}

static void alias_find_window(struct alias* alias) {
  struct menu_item_list menu_item_list = get_menu_item_list();
  
  for (int i = 0; i < menu_item_list.menu_item_count; ++i) {
    struct menu_item* item = menu_item_list.menu_items + i;
    if (!alias->owner || strcmp(alias->owner, item->owner) != 0) continue;
    if (!alias->name || strcmp(alias->name, item->name) != 0) {
      if (alias->name) {
        char indexed_name[strlen(alias->name) + 32];
        snprintf(indexed_name, strlen(alias->name) + 32,
                               "%s(%d)",
                               item->name,
                               i + 1                    );
        if (strcmp(alias->name, indexed_name) != 0) continue; 
      } else if (strcmp(item->name, "") != 0) continue;
    }

    alias->window.id = item->wid;
    alias->pid = item->pid;
    alias->window.frame.size = item->bounds.size;
    alias->window.origin = item->bounds.origin;

    menu_item_list_clear(&menu_item_list);
    return;
  }
  alias->window.id = 0;
  menu_item_list_clear(&menu_item_list);
}

static int compare_frames_by_x(const void* a, const void* b) {
  const CGRect* lhs = a;
  const CGRect* rhs = b;
  // Hidden items (pushed off screen, e.g. behind the notch) sort last.
  bool lhs_hidden = lhs->origin.x < 0;
  bool rhs_hidden = rhs->origin.x < 0;
  if (lhs_hidden != rhs_hidden) return lhs_hidden ? 1 : -1;
  return (lhs->origin.x > rhs->origin.x) - (lhs->origin.x < rhs->origin.x);
}

// Finds the status item named by `owner,N` (the owner's N-th item from the
// left, 1 when no N is given) through Accessibility, and the menu bar window
// that draws it.
static bool alias_find_status_item(struct alias* alias) {
  alias->status_item = false;
  alias->menubar = 0;
  pid_t pid = workspace_pid_for_app_name(alias->owner);
  if (pid <= 0) return false;

  AXUIElementRef app = AXUIElementCreateApplication(pid);
  if (!app) return false;
  AXUIElementSetMessagingTimeout(app, 0.5);

  CGRect frames[32];
  int count = 0;
  CFTypeRef extras = NULL;
  if (AXUIElementCopyAttributeValue(app, CFSTR("AXExtrasMenuBar"), &extras)
        == kAXErrorSuccess && extras) {
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute, &children)
          == kAXErrorSuccess && children) {
      CFIndex total = CFArrayGetCount(children);
      for (CFIndex i = 0; i < total && count < 32; i++) {
        AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
        CFTypeRef position_ref = NULL;
        CFTypeRef size_ref = NULL;
        CGPoint position = CGPointZero;
        CGSize size = CGSizeZero;
        if (AXUIElementCopyAttributeValue(child, kAXPositionAttribute, &position_ref)
              == kAXErrorSuccess && position_ref) {
          AXValueGetValue(position_ref, kAXValueTypeCGPoint, &position);
          CFRelease(position_ref);
        }
        if (AXUIElementCopyAttributeValue(child, kAXSizeAttribute, &size_ref)
              == kAXErrorSuccess && size_ref) {
          AXValueGetValue(size_ref, kAXValueTypeCGSize, &size);
          CFRelease(size_ref);
        }
        if (size.width > 0 && size.height > 0) {
          frames[count++] = (CGRect){ position, size };
        }
      }
      CFRelease(children);
    }
    CFRelease(extras);
  }
  CFRelease(app);
  if (count == 0) return false;

  qsort(frames, count, sizeof(CGRect), compare_frames_by_x);
  long index = alias->name && alias->name[0] ? strtol(alias->name, NULL, 10) : 1;
  if (index < 1) index = 1;
  if (index > count) return false;

  alias->status_item = true;
  alias->pid = pid;
  alias->item_frame = frames[index - 1];
  alias->window.origin = alias->item_frame.origin;
  alias->window.frame.size = alias->item_frame.size;

  // The menu bar window covering the item's centre draws it. It is not
  // reported as on screen, so every window is searched.
  CGPoint center = { CGRectGetMidX(alias->item_frame),
                     CGRectGetMidY(alias->item_frame) };
  CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll,
                                                  kCGNullWindowID        );
  if (!windows) return true;
  for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
    CFDictionaryRef window = CFArrayGetValueAtIndex(windows, i);
    CFNumberRef layer_ref = CFDictionaryGetValue(window, kCGWindowLayer);
    CFStringRef owner_ref = CFDictionaryGetValue(window, kCGWindowOwnerName);
    CFDictionaryRef bounds_ref = CFDictionaryGetValue(window, kCGWindowBounds);
    CFNumberRef id_ref = CFDictionaryGetValue(window, kCGWindowNumber);
    if (!layer_ref || !owner_ref || !bounds_ref || !id_ref) continue;

    int layer = 0;
    CFNumberGetValue(layer_ref, kCFNumberIntType, &layer);
    if (layer != kCGMainMenuWindowLevel) continue;
    if (CFStringCompare(owner_ref, CFSTR("MenuBarAgent"), 0) != kCFCompareEqualTo) continue;

    CGRect bounds;
    if (!CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds)) continue;
    if (!CGRectContainsPoint(bounds, center)) continue;

    uint32_t wid = 0;
    CFNumberGetValue(id_ref, kCFNumberSInt32Type, &wid);
    alias->menubar = wid;
    alias->menubar_frame = bounds;
    break;
  }
  CFRelease(windows);
  return true;
}

// Crops `image` to the columns any update has drawn in so far. Returns the
// cropped image, retained, and releases `image`.
static CGImageRef alias_trim(struct alias* alias, CGImageRef image) {
  size_t width = CGImageGetWidth(image);
  size_t height = CGImageGetHeight(image);
  if (width == 0 || height == 0) return image;

  uint8_t* pixels = calloc(width * height, 4);
  if (!pixels) return image;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8,
                                               width * 4, space,
                                               kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (!context) {
    free(pixels);
    return image;
  }
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
  CGContextRelease(context);

  int left = -1, right = -1;
  for (size_t x = 0; x < width; x++) {
    for (size_t y = 0; y < height; y++) {
      if (pixels[(y * width + x) * 4 + 3] > 16) {
        if (left < 0) left = x;
        right = x;
        break;
      }
    }
  }
  free(pixels);
  if (left < 0) return image;

  CGSize size = { width, height };
  if (!CGSizeEqualToSize(size, alias->trim_size)) {
    alias->trim_size = size;
    alias->trim_left = left;
    alias->trim_right = right;
  } else {
    if (left < alias->trim_left) alias->trim_left = left;
    if (right > alias->trim_right) alias->trim_right = right;
  }

  CGRect crop = CGRectMake(alias->trim_left, 0,
                           alias->trim_right - alias->trim_left + 1, height);
  CGImageRef trimmed = CGImageCreateWithImageInRect(image, crop);
  if (!trimmed) return image;
  CGImageRelease(image);
  return trimmed;
}

// Crops the item out of the menu bar window it is drawn into. A hidden item
// shows its app's icon instead.
static bool alias_update_status_item(struct alias* alias, bool forced) {
  if (!alias_find_status_item(alias)) {
    image_destroy(&alias->image);
    return false;
  }

  CGImageRef image_ref = NULL;
  CGRect bounds = { CGPointZero, alias->item_frame.size };
  if (alias->menubar) {
    struct window menubar;
    memset(&menubar, 0, sizeof(struct window));
    menubar.id = alias->menubar;
    bool disabled = false;
    CGImageRef full = window_capture(&menubar, &disabled);
    if (!full) return false;

    CGFloat scale = CGImageGetWidth(full) / alias->menubar_frame.size.width;
    CGRect crop = {
      { (alias->item_frame.origin.x - alias->menubar_frame.origin.x) * scale,
        (alias->item_frame.origin.y - alias->menubar_frame.origin.y) * scale },
      { alias->item_frame.size.width * scale,
        alias->item_frame.size.height * scale }
    };
    image_ref = CGImageCreateWithImageInRect(full, crop);
    CGImageRelease(full);
    if (image_ref && alias->trim) {
      image_ref = alias_trim(alias, image_ref);
      bounds.size.width = CGImageGetWidth(image_ref) / scale;
    }
  } else {
    image_ref = workspace_icon_for_app(alias->owner);
    bounds.size = (CGSize){ 20, 20 };
  }
  if (!image_ref) return false;

  return image_set_image(&alias->image, image_ref, bounds, forced);
}

// The status item this alias mirrors, retained: among its owner's status
// items, the one closest to the mirrored position.
static AXUIElementRef alias_copy_ax_item(struct alias* alias) {
  AXUIElementRef app = AXUIElementCreateApplication(alias->pid);
  if (!app) return NULL;
  AXUIElementSetMessagingTimeout(app, 0.5);

  AXUIElementRef target = NULL;
  CFTypeRef extras = NULL;
  if (AXUIElementCopyAttributeValue(app, CFSTR("AXExtrasMenuBar"), &extras)
        == kAXErrorSuccess && extras) {
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute, &children)
          == kAXErrorSuccess && children) {
      CGFloat best = CGFLOAT_MAX;
      CFIndex count = CFArrayGetCount(children);
      for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
        CFTypeRef value = NULL;
        CGPoint position = CGPointZero;
        if (AXUIElementCopyAttributeValue(child, kAXPositionAttribute, &value)
              != kAXErrorSuccess || !value) {
          if (count == 1) target = child;
          continue;
        }
        AXValueGetValue(value, kAXValueTypeCGPoint, &position);
        CFRelease(value);

        CGFloat distance = fabs(position.x - alias->window.origin.x)
                           + fabs(position.y - alias->window.origin.y);
        if (distance < best) {
          best = distance;
          target = child;
        }
      }
      if (target) CFRetain(target);
      CFRelease(children);
    }
    CFRelease(extras);
  }
  CFRelease(app);
  return target;
}

static AXUIElementRef alias_copy_ax_menu(AXUIElementRef item) {
  CFTypeRef children = NULL;
  if (AXUIElementCopyAttributeValue(item, kAXChildrenAttribute, &children)
        != kAXErrorSuccess || !children) {
    return NULL;
  }
  AXUIElementRef menu = NULL;
  for (CFIndex i = 0; i < CFArrayGetCount(children) && !menu; i++) {
    AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
    CFTypeRef role = NULL;
    if (AXUIElementCopyAttributeValue(child, kAXRoleAttribute, &role)
          == kAXErrorSuccess && role) {
      if (CFEqual(role, kAXMenuRole)) menu = (AXUIElementRef)CFRetain(child);
      CFRelease(role);
    }
  }
  CFRelease(children);
  return menu;
}

// Clicks the menu bar item this alias mirrors, and opens what it opens under
// `anchor`, the alias on screen. An item with a menu shows a copy of that menu
// there; any other item is pressed, and the panel it opens is moved there.
// Needs Accessibility permission.
bool alias_press(struct alias* alias, CGRect anchor) {
  if (alias->status_item) alias_find_status_item(alias);
  else alias_find_window(alias);
  if ((!alias->window.id && !alias->status_item) || alias->pid <= 0) return false;

  bool hidden = alias->status_item && !alias->menubar;
  if (!AXIsProcessTrusted()) {
    printf("[!] Alias: clicking '%s' needs Accessibility permission\n",
           alias->owner ? alias->owner : "");
    return hidden && workspace_activate_app(alias->pid);
  }

  AXUIElementRef item = alias_copy_ax_item(alias);
  if (!item) return hidden && workspace_activate_app(alias->pid);

  // A menu can be read without opening it, so it works even for an item
  // hidden behind the notch.
  bool opened = false;
  AXUIElementRef menu = alias_copy_ax_menu(item);
  if (menu) {
    opened = alias_menu_show(menu, anchor);
    CFRelease(menu);
  }

  if (!opened && hidden) {
    // macOS has nowhere to open anything else for a hidden item: bring its
    // app forward instead.
    opened = workspace_activate_app(alias->pid);
  } else if (!opened) {
    alias_menu_follow_window(alias->pid, alias->window.frame.size.width > 0
                                         ? (CGRect){ alias->window.origin,
                                                     alias->window.frame.size }
                                         : anchor,
                             anchor);
    // The press only returns once whatever it opens closes, and that only
    // opens once the press returns, so it must time out quickly. A short
    // timeout also keeps a hung app from stalling the bar.
    AXUIElementSetMessagingTimeout(item, 0.1);
    AXError error = AXUIElementPerformAction(item, kAXPressAction);
    opened = error == kAXErrorSuccess || error == kAXErrorCannotComplete;
  }
  CFRelease(item);
  return opened;
}

static bool alias_update_image(struct alias* alias, bool forced) {
  if (alias->status_item) return alias_update_status_item(alias, forced);
  if (alias->window.id == 0) alias_find_window(alias);
  if (alias->window.id == 0 && alias_find_status_item(alias)) {
    return alias_update_status_item(alias, forced);
  }
  if (alias->window.id == 0) return false;

  bool disabled = false;
  CGImageRef image_ref = window_capture(&alias->window, &disabled);

  if (!image_ref) {
    if (!disabled) {
      alias->window.id = 0;
      image_destroy(&alias->image);
    }
    return false;
  }

  return image_set_image(&alias->image,
                         image_ref,
                         alias->window.frame,
                         forced              );
}

void alias_setup(struct alias* alias, char* owner, char* name) {
  alias->name = name;
  alias->owner = owner;
  alias_get_permission(alias);
  alias_update_image(alias, true);
}

uint32_t alias_get_length(struct alias* alias) {
  if (alias->image.image_ref) return alias->image.bounds.size.width;
  return 0;
}

uint32_t alias_get_height(struct alias* alias) {
  if (alias->image.image_ref) return alias->image.bounds.size.height;
  return 0;
}

bool alias_update(struct alias* alias, bool forced) {
  if (alias->update_frequency == 0) return false;

  alias->counter++;
  if (forced || alias->counter >= alias->update_frequency) {
    alias->counter = 0;
    if (alias_update_image(alias, forced)) {
      return true;
    }
  }
  return false;
}

void alias_draw(struct alias* alias, CGContextRef context) {
  if (alias->color_override) {
    CGContextSaveGState(context);
    image_draw(&alias->image, context);
    CGContextClipToMask(context, alias->image.bounds, alias->image.image_ref);
    CGContextSetRGBFillColor(context,
                             alias->color.r,
                             alias->color.g,
                             alias->color.b,
                             alias->color.a );

    CGContextFillRect(context, alias->image.bounds);
    CGContextRestoreGState(context);
  }
  else {
    image_draw(&alias->image, context);
  }
}

void alias_destroy(struct alias* alias) {
  image_destroy(&alias->image);
  if (alias->name) free(alias->name);
  if (alias->owner) free(alias->owner);
  alias->name = NULL;
  alias->owner = NULL;
}

void alias_calculate_bounds(struct alias* alias, uint32_t x, uint32_t y) {
  image_calculate_bounds(&alias->image, x, y);
}

bool alias_parse_sub_domain(struct alias* alias, FILE* rsp, struct token property, char* message) {
  struct key_value_pair key_value_pair = get_key_value_pair(property.text,'.');
  if (key_value_pair.key && key_value_pair.value) {
    struct token subdom = { key_value_pair.key, strlen(key_value_pair.key) };
    struct token entry = { key_value_pair.value, strlen(key_value_pair.value)};
    if (token_equals(subdom, SUB_DOMAIN_SHADOW))
      return shadow_parse_sub_domain(&alias->image.shadow,
                                     rsp,
                                     entry,
                                     message              );
    else if (token_equals(subdom, SUB_DOMAIN_COLOR)) {
      bool changed = !alias->color_override;
      alias->color_override = true;
      return color_parse_sub_domain(&alias->color, rsp, entry, message)
            || changed;
    }
    else {
      respond(rsp, "[!] Alias: Invalid subdomain '%s'\n", subdom.text);
    }
  }
  else if (token_equals(property, PROPERTY_COLOR)) {
    color_set_hex(&alias->color, token_to_uint32t(get_token(&message)));
    alias->color_override = true;
    return true;
  } else if (token_equals(property, PROPERTY_SCALE)) {
    return image_set_scale(&alias->image, token_to_float(get_token(&message)));
  } else if (token_equals(property, PROPERTY_UPDATE_FREQ)) {
    alias->update_frequency = token_to_uint32t(get_token(&message));
    return false;
  } else if (token_equals(property, PROPERTY_TRIM)) {
    alias->trim = evaluate_boolean_state(get_token(&message), alias->trim);
    alias->trim_size = CGSizeZero;
    return alias_update(alias, true);
  } else {
    respond(rsp, "[!] Alias: Invalid property '%s' \n", property.text);
  }
  return false;
}
