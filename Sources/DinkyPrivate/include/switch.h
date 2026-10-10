#pragma once
#import <Foundation/Foundation.h>

// Uses the legacy Dock swipe only on macOS 15; all other majors use mimi's augmented swipe. RESULTS.md records paths tried.
// Swipes from fromIndex to toIndex (1-based) on the display with displayUUID and returns whether
// posting succeeded. Refuses an unknown display. Does not wait for the switch, but warps the cursor to
// that display for the swipe when it is elsewhere and waits about 60 ms to put it back.
bool dinky_switch_to_space_index(int fromIndex, int toIndex, CFStringRef displayUUID);
