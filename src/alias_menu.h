#pragma once
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

// macOS opens a status item's menu or panel under the item in the menu bar,
// not under its alias in the bar. These put it under the alias instead.
// `anchor` is the alias on screen, in global top-left coordinates.

// Shows `menu`, the AXMenu of another app's status item, as a menu of our own
// under `anchor`. Choosing an entry presses the app's own menu item. Returns
// false when the menu has no entries to show.
bool alias_menu_show(AXUIElementRef menu, CGRect anchor);

// Watches for the window `pid` opens below `item` (its status item in the
// menu bar) once the item is pressed, and moves it under `anchor`. Call it
// before pressing the item.
void alias_menu_follow_window(pid_t pid, CGRect item, CGRect anchor);
