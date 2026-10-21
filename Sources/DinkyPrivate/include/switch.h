#pragma once
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// Only the mimi augmented swipe is left; RESULTS.md records the paths the spike tried.
// Swipes from fromIndex to toIndex (1-based) on the display with displayUUID and returns whether
// posting succeeded. Refuses an unknown display. Does not wait for the switch, but warps the cursor to
// that display for the swipe when it is elsewhere and waits about 60 ms to put it back.
bool dinky_switch_to_space_index(int fromIndex, int toIndex, CFStringRef displayUUID);

// Real Dock swipes, for the trackpad swipe tap (Swipe.swift).

typedef NS_ENUM(int, DinkySwipePhase) {
    DinkySwipePhaseBegan = 1,
    DinkySwipePhaseChanged = 2,
    DinkySwipePhaseEnded = 4,
    DinkySwipePhaseCancelled = 8,
};

/// The events a tap needs to see the Dock swipe: Dock control events and the gesture events that come with them.
CGEventMask dinky_dock_swipe_event_mask(void);
/// Reads a Dock swipe: its phase, whether it runs up and down (Mission Control and App Exposé) rather than sideways
/// (Spaces), and the way it heads: +1 toward what is right (a higher Space index) or below, -1 toward what is left
/// or above, 0 while it has not moved. False for any other event.
bool dinky_read_dock_swipe(CGEventRef event, DinkySwipePhase *phase, bool *vertical, int *direction);
/// Whether the event is one of the gesture events that come with a Dock swipe.
bool dinky_is_gesture_event(CGEventRef event);
/// Clears a Dock swipe event's progress and velocity, so passing it on goes nowhere.
void dinky_neutralize_dock_swipe(CGEventRef event);
/// Whether the Dock passes a swipe event on to its gesture state only with the macOS 27 payload attached.
bool dinky_dock_swipe_needs_payload(void);
/// Whether a Dock swipe event is one dinky posted to switch Spaces, which a tap must let through. Counts it off.
bool dinky_take_own_dock_swipe(void);
/// Forgets the Dock swipe events dinky posted that no tap has seen yet.
void dinky_forget_own_dock_swipes(void);
