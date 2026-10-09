#import "events.h"
#import "query.h"
#import "skylight.h"
#include <dlfcn.h>

// Notify procs, as JankyBorders src/events.c registers them. Observed on 27.0: the handler gets
// (type, data, length, context); JankyBorders' fourth parameter is the context it passed in.
typedef void (*NotifyProc)(uint32_t type, void *data, size_t length, void *context);
extern CGError SLSRegisterNotifyProc(NotifyProc handler, uint32_t type, void *context);
extern CGError SLSRemoveNotifyProc(NotifyProc handler, uint32_t type, void *context);
extern CGError SLSRequestNotificationsForWindows(int cid, const uint32_t *windowIDs, int count);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSWindowIsOrderedIn(int cid, uint32_t wid, uint8_t *orderedIn);
// macOS 26 and later. Resolve dynamically to avoid a hard link dependency on newer SDKs.
typedef CFArrayRef (*WindowIteratorGetCornerRadiiFn)(CFTypeRef iterator);
static WindowIteratorGetCornerRadiiFn window_iterator_get_corner_radii(void)
{
    static dispatch_once_t once;
    static WindowIteratorGetCornerRadiiFn function;
    dispatch_once(&once, ^{
        function = (WindowIteratorGetCornerRadiiFn)dlsym(RTLD_DEFAULT, "SLSWindowIteratorGetCornerRadii");
    });
    return function;
}

static const DinkyEventKind kinds[] = {
    DinkyEventWindowUpdate, DinkyEventWindowClose, DinkyEventWindowMove, DinkyEventWindowResize,
    DinkyEventWindowReorder, DinkyEventWindowLevel, DinkyEventWindowUnhide, DinkyEventWindowHide,
    DinkyEventWindowTitle, DinkyEventWindowCreate, DinkyEventWindowDestroy,
    DinkyEventSpaceCreated, DinkyEventSpaceDestroyed, DinkyEventSpaceChange, DinkyEventFrontApp,
};
static const int kind_count = sizeof(kinds) / sizeof(kinds[0]);

static DinkyEventCallback event_callback = NULL;
static void *event_context = NULL;

static pid_t connection_pid(int cid)
{
    pid_t pid = 0;
    if (cid) SLSConnectionGetPID(cid, &pid);
    return pid > 0 ? pid : 0;  // -1 once the owner is gone
}

// JankyBorders is_own_window: window -> owning connection -> pid.
static pid_t window_pid(uint32_t wid)
{
    int owner = 0;
    if (SLSGetWindowOwner(dinky_connection(), wid, &owner) != kCGErrorSuccess) return 0;
    return connection_pid(owner);
}

static void handler(uint32_t type, void *data, size_t length, void *context)
{
    DinkyEvent event = { .kind = type };

    switch (type) {
    case DinkyEventWindowCreate:
    case DinkyEventWindowDestroy:
        // JankyBorders struct window_spawn_data: uint64 sid at 0, uint32 wid at 8 (12 bytes).
        if (length < 12) return;
        memcpy(&event.spaceID, data, sizeof(uint64_t));
        memcpy(&event.windowID, (uint8_t *)data + 8, sizeof(uint32_t));
        event.pid = window_pid(event.windowID);
        break;
    case DinkyEventSpaceCreated:
    case DinkyEventSpaceDestroyed:
        // yabai mission_control.c connection_handler 1327/1328: uint64 sid at 0.
        if (length < 8) return;
        memcpy(&event.spaceID, data, sizeof(uint64_t));
        break;
    case DinkyEventSpaceChange:
        // JankyBorders space_handler ignores the payload; so do we.
        break;
    case DinkyEventFrontApp:
        // 1508 carries no payload on 27.0; ask for the front app instead.
        event.pid = connection_pid(dinky_front_connection());
        break;
    default:
        // JankyBorders window_modify_handler and yabai 804/808: uint32 wid at 0.
        if (length < 4) return;
        memcpy(&event.windowID, data, sizeof(uint32_t));
        event.pid = window_pid(event.windowID);
        break;
    }

    if (event_callback) event_callback(event, event_context);
}

static void stop(void)
{
    for (int i = 0; i < kind_count; ++i) SLSRemoveNotifyProc(handler, kinds[i], NULL);
    event_callback = NULL;
    event_context = NULL;
}

bool dinky_events_start(DinkyEventCallback callback, void *context)
{
    event_callback = callback;
    event_context = context;
    for (int i = 0; i < kind_count; ++i) {
        if (SLSRegisterNotifyProc(handler, kinds[i], NULL) != kCGErrorSuccess) {
            fprintf(stderr, "events: SLSRegisterNotifyProc(%u) failed\n", kinds[i]);
            stop();
            return false;
        }
    }
    return true;
}

void dinky_events_watch_windows(const uint32_t *windowIDs, int count)
{
    SLSRequestNotificationsForWindows(dinky_connection(), windowIDs, count);
}

DinkyWindowInfo dinky_window_info(uint32_t windowID)
{
    int cid = dinky_connection();
    DinkyWindowInfo info = { .windowID = windowID };

    NSArray *windows = @[@(windowID)];
    CFTypeRef query = SLSWindowQueryWindows(cid, (__bridge CFArrayRef)windows, 1);
    if (!query) return info;
    CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);

    if (iterator && SLSWindowIteratorGetCount(iterator) > 0 && SLSWindowIteratorAdvance(iterator)) {
        info.exists = true;
        info.level = SLSWindowIteratorGetLevel(iterator);
        info.parentID = SLSWindowIteratorGetParentID(iterator);
        info.tags = SLSWindowIteratorGetTags(iterator);
        info.attributes = SLSWindowIteratorGetAttributes(iterator);

        // JankyBorders windows_window_create: first entry of the radii array, released after.
        WindowIteratorGetCornerRadiiFn getCornerRadii = window_iterator_get_corner_radii();
        if (getCornerRadii) {
            CFArrayRef radii = getCornerRadii(iterator);
            if (radii && CFArrayGetCount(radii) > 0) {
                CFNumberGetValue(CFArrayGetValueAtIndex(radii, 0), kCFNumberIntType, &info.cornerRadius);
            }
            if (radii) CFRelease(radii);
        }
    }
    if (iterator) CFRelease(iterator);
    CFRelease(query);
    if (!info.exists) return info;

    uint8_t orderedIn = 0;
    SLSWindowIsOrderedIn(cid, windowID, &orderedIn);
    info.isOrderedIn = orderedIn;
    SLSGetWindowBounds(cid, windowID, &info.frame);
    info.pid = window_pid(windowID);

    info.isDocument = dinky_is_document_kind(info.parentID, info.tags);
    info.isVisible = dinky_is_visible(info.attributes, info.tags);
    info.isMinimized = dinky_is_minimized(info.attributes, info.tags);
    return info;
}

NSArray<NSNumber *> *dinky_all_window_ids(void)
{
    NSMutableOrderedSet *result = [NSMutableOrderedSet orderedSet];
    for (DinkyDisplay *display in dinky_displays()) {
        for (DinkySpace *space in display.spaces) {
            [result addObjectsFromArray:dinky_space_window_ids(space.spaceID, true)];
        }
    }
    return result.array;
}
