#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// WindowServer notification types, the numbers SLSRegisterNotifyProc takes.
// From JankyBorders src/events.h; SpaceCreated/Destroyed from yabai src/yabai.c.
typedef NS_ENUM(uint32_t, DinkyEventKind) {
    DinkyEventWindowUpdate = 723,
    DinkyEventWindowClose = 804,
    DinkyEventWindowMove = 806,
    DinkyEventWindowResize = 807,
    DinkyEventWindowReorder = 808,
    DinkyEventWindowLevel = 811,
    DinkyEventWindowUnhide = 815,
    DinkyEventWindowHide = 816,
    DinkyEventWindowTitle = 1322,
    DinkyEventWindowCreate = 1325,
    DinkyEventWindowDestroy = 1326,
    DinkyEventSpaceCreated = 1327,
    DinkyEventSpaceDestroyed = 1328,
    DinkyEventSpaceChange = 1401,
    DinkyEventFrontApp = 1508,
};

typedef struct {
    DinkyEventKind kind;
    uint32_t windowID;  // 0 for Space and front app events
    pid_t pid;          // window owner, or the front app for DinkyEventFrontApp; 0 if gone, and for a move
    uint64_t spaceID;   // create/destroy and Space created/destroyed only, else 0
} DinkyEvent;

typedef void (*DinkyEventCallback)(DinkyEvent event, void *_Nullable context);

// Registers for every DinkyEventKind on the main connection. Callbacks run on the main
// thread, from inside the AppKit event loop: SkyLight dispatches notify procs while it
// drains the connection's event port, which [NSApp run] does. Without a running
// NSApplication nothing is delivered. Returns false if registration failed.
bool dinky_events_start(DinkyEventCallback callback, void *_Nullable context);

// The per-window events (close, move, resize, reorder, level, hide, unhide) only arrive
// for windows named here. Each call replaces the previous list.
void dinky_events_watch_windows(const uint32_t *windowIDs, int count);

typedef struct {
    bool exists;
    uint32_t windowID;
    pid_t pid;
    CGRect frame;          // global display coordinates, top-left origin
    int level;
    uint32_t parentID;
    uint64_t tags;
    uint64_t attributes;
    bool isOrderedIn;
    bool isDocument;       // JankyBorders window_suitable, kind only: a real document or modal window
    bool isVisible;        // the visible attribute or tag; clear while minimized
    bool isMinimized;      // yabai space_window_list minimized test
} DinkyWindowInfo;

DinkyWindowInfo dinky_window_info(uint32_t windowID);

// The window's corner radius, 0 if SkyLight does not report one. SkyLight leaks the radii it reports
// whenever they are not whole numbers, so this is read once per window rather than with every info read.
int dinky_window_corner_radius(uint32_t windowID);

// The frame alone, in one call where dinky_window_info makes several: for a window that moved.
// CGRectNull if the window is gone.
CGRect dinky_window_frame(uint32_t windowID);

// Every window on every Space, minimized included, filtered like dinky_space_window_ids.
NSArray<NSNumber *> *dinky_all_window_ids(void);

NS_ASSUME_NONNULL_END
