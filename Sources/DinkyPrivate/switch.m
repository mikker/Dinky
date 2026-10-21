#import "switch.h"
#import "query.h"

#import <AppKit/AppKit.h>
#import <mach/mach_time.h>

// Switches Spaces with mimi's augmented Dock swipe (mimi internal/native/space.m + dockswipe.m).
// RESULTS.md records the other paths the spike tried and why this one won.

// Private CGEvent field numbers for a synthetic Dock swipe.
static const int kEventTypeField = 55;             // kCGSEventTypeField
static const int kEventGesture = 29;               // kCGSEventGesture
static const int kEventDockControl = 30;           // kCGSEventDockControl
static const int kGestureHIDType = 110;            // kCGEventGestureHIDType
static const int kHIDEventTypeDockSwipe = 23;      // kIOHIDEventTypeDockSwipe
static const int kGestureSwipeMask = 115;          // kCGEventGestureSwipeMask
static const int kGestureSwipeMotion = 123;        // kCGEventGestureSwipeMotion
static const int kGestureMotionHorizontal = 1;     // kCGGestureMotionHorizontal
static const int kGestureMotionVertical = 2;       // kCGGestureMotionVertical
static const int kGestureSwipeProgress = 124;      // kCGEventGestureSwipeProgress
static const int kGestureSwipePositionX = 125;     // kCGEventGestureSwipePositionX
static const int kGestureSwipePositionY = 126;     // kCGEventGestureSwipePositionY
static const int kGestureSwipeVelocityX = 129;     // kCGEventGestureSwipeVelocityX
static const int kGestureSwipeVelocityY = 130;     // kCGEventGestureSwipeVelocityY
static const int kGesturePhase = 132;              // kCGEventGesturePhase
static const int kGesturePhaseAlias = 134;         // kCGEventGesturePhaseAlias
static const int kGestureZoomDeltaY = 138;         // kCGEventGestureZoomDeltaY
static const int kSourceUnixProcessIDAlias = 169;  // kCGEventSourceUnixProcessIDAlias
static const int kPhaseBegan = 1;
static const int kPhaseChanged = 2;
static const int kPhaseEnded = 4;

// Dock swipe events dinky posted that the swipe tap has not seen yet, and when the last was posted. A tap sees
// dinky's own swipes as it sees the trackpad's; nothing that survives posting marks them, so they are counted
// off as they come by, as iss does.
static int own_dock_events = 0;
static uint64_t own_dock_events_at = 0;

static void post_dock_event(CGEventRef event)
{
    own_dock_events++;
    own_dock_events_at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    CGEventPost(kCGSessionEventTap, event);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// IOHID queue layout the Dock reads out of a synthetic dock swipe on macOS 27+. From mimi dockswipe.m.
#pragma pack(push, 1)
typedef struct {
    uint32_t size;
    uint32_t type;
    uint32_t options;
    uint8_t depth;
    uint8_t reserved[3];
} IOHIDEventBase;

typedef struct {
    IOHIDEventBase base;
    int32_t positionX;
    int32_t positionY;
    int32_t positionZ;
    uint32_t swipeMask;
    uint16_t gestureMotion;
    uint16_t gestureFlavor;
    int32_t swipeProgress;
} IOHIDFluidTouchGestureData;

typedef struct {
    IOHIDEventBase base;
    int32_t velocityX;
    int32_t velocityY;
    int32_t velocityZ;
} IOHIDVelocityEventData;

typedef struct {
    uint64_t timestamp;
    uint64_t senderID;
    uint32_t options;
    uint32_t attributeLength;
    uint32_t eventCount;
} IOHIDSystemQueueElementHeader;
#pragma pack(pop)

_Static_assert(sizeof(IOHIDEventBase) == 16, "unexpected IOHID event base layout");
_Static_assert(sizeof(IOHIDFluidTouchGestureData) == 40, "unexpected IOHID fluid gesture layout");
_Static_assert(sizeof(IOHIDVelocityEventData) == 28, "unexpected IOHID velocity layout");
_Static_assert(sizeof(IOHIDSystemQueueElementHeader) == 28, "unexpected IOHID queue header layout");

static const uint32_t kIOHIDEventTypeVelocity = 9;
static const uint32_t kIOHIDEventTypeFluidTouchGesture = 23;
static const uint16_t kIOHIDGestureFlavorDockPrimary = 3;
static const uint16_t kRawIOHIDPayloadField = 4205;
static const uint8_t kEventDataFormatVersion = 2;

static const double kMimiZoomDeltaY = 3.0;          // empirically required
static const double kMimiPositionX = 0.1;           // empirically required
static const double kMimiVelocity = 9999.0;         // high enough to skip the animation
// The legacy swipe's velocity. At 200 or more macOS skips the animation and never tells the windows of the
// Space it lands on that they are visible again, so apps that stop drawing while hidden, like Ghostty, stay
// blank until something else brings them forward. At 100 a three-swipe switch only went two Spaces and lost
// the update again; at 50 every single and back-to-back switch landed and updated, about 60-120 ms per swipe.
// Measured on an Intel Mac with macOS 26.7.1.
static const double kLegacyVelocity = 50.0;
static const CFTimeInterval kMimiStepDelay = 0.03;  // mimi kMimiSpaceGestureProcessingDelay

static int32_t fixed_1616(double value)
{
    int32_t fixed = (int32_t)(value * 65536.0);
    if (fixed == 0 && value != 0.0) return value > 0.0 ? 1 : -1;
    return fixed;
}

static uint8_t *build_iohid_payload(CGEventRef event, size_t *outLength)
{
    int64_t phase = CGEventGetIntegerValueField(event, kGesturePhase);
    int64_t motion = CGEventGetIntegerValueField(event, kGestureSwipeMotion);
    int64_t swipeMask = CGEventGetIntegerValueField(event, kGestureSwipeMask);
    double progress = CGEventGetDoubleValueField(event, kGestureSwipeProgress);
    double posX = CGEventGetDoubleValueField(event, kGestureSwipePositionX);
    double posY = CGEventGetDoubleValueField(event, kGestureSwipePositionY);
    double velX = CGEventGetDoubleValueField(event, kGestureSwipeVelocityX);
    double velY = CGEventGetDoubleValueField(event, kGestureSwipeVelocityY);

    // A real trackpad only reports velocity once the fingers lift.
    bool includeVelocity = (velX != 0.0 || velY != 0.0 || phase == kPhaseEnded);

    size_t length = sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData);
    if (includeVelocity) length += sizeof(IOHIDVelocityEventData);

    uint8_t *payload = calloc(1, length);
    if (!payload) return NULL;

    IOHIDSystemQueueElementHeader *header = (IOHIDSystemQueueElementHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp != 0 ? timestamp : mach_absolute_time();
    header->eventCount = includeVelocity ? 2 : 1;

    IOHIDFluidTouchGestureData *fluid = (IOHIDFluidTouchGestureData *)(payload + sizeof(IOHIDSystemQueueElementHeader));
    fluid->base.size = sizeof(IOHIDFluidTouchGestureData);
    fluid->base.type = kIOHIDEventTypeFluidTouchGesture;
    fluid->base.options = (uint32_t)((phase & 0xFF) << 24);
    fluid->positionX = fixed_1616(posX);
    fluid->positionY = fixed_1616(posY);
    fluid->swipeMask = (uint32_t)swipeMask;
    fluid->gestureMotion = (uint16_t)motion;
    fluid->gestureFlavor = kIOHIDGestureFlavorDockPrimary;
    fluid->swipeProgress = fixed_1616(progress);

    if (includeVelocity) {
        IOHIDVelocityEventData *velocity = (IOHIDVelocityEventData *)(payload + sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData));
        velocity->base.size = sizeof(IOHIDVelocityEventData);
        velocity->base.type = kIOHIDEventTypeVelocity;
        velocity->base.depth = 1;
        velocity->velocityX = fixed_1616(velX);
        velocity->velocityY = fixed_1616(velY);
    }

    *outLength = length;
    return payload;
}

// mimi MimiDockSwipeAugment: serialize the event, append the IOHID payload as a trailing field, rebuild.
static CGEventRef dock_swipe_augment(CGEventRef event)
{
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) {
        fputs("switch: could not serialize dock swipe event\n", stderr);
        return NULL;
    }

    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    if (length < 4 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != kEventDataFormatVersion) {
        fprintf(stderr, "switch: unexpected event data format (length=%ld)\n", (long)length);
        CFRelease(data);
        return NULL;
    }

    size_t payloadLength = 0;
    uint8_t *payload = build_iohid_payload(event, &payloadLength);
    if (!payload) {
        CFRelease(data);
        return NULL;
    }

    // Serialized event, then big-endian payload length and field ID, then the payload.
    size_t newLength = (size_t)length + 4 + payloadLength;
    uint8_t *newBytes = malloc(newLength);
    if (!newBytes) {
        free(payload);
        CFRelease(data);
        return NULL;
    }
    memcpy(newBytes, bytes, (size_t)length);
    newBytes[length] = (uint8_t)((payloadLength >> 8) & 0xFF);
    newBytes[length + 1] = (uint8_t)(payloadLength & 0xFF);
    newBytes[length + 2] = (uint8_t)((kRawIOHIDPayloadField >> 8) & 0xFF);
    newBytes[length + 3] = (uint8_t)(kRawIOHIDPayloadField & 0xFF);
    memcpy(newBytes + length + 4, payload, payloadLength);
    free(payload);
    CFRelease(data);

    CFDataRef newData = CFDataCreate(kCFAllocatorDefault, newBytes, (CFIndex)newLength);
    free(newBytes);
    if (!newData) return NULL;

    CGEventRef augmented = CGEventCreateFromData(kCFAllocatorDefault, newData);
    CFRelease(newData);
    if (!augmented) fputs("switch: could not rebuild dock swipe event from data\n", stderr);
    return augmented;
}

// mimi MimiDockSwipeRequiresAugmentation: the Dock reads the IOHID payload from macOS 27 on. Before that it
// reads the plain CGEvent fields, with the Space-index sign.
static bool requires_augmentation(void)
{
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

// mimi mimiAugmentedDockSwipeSign: the sign the macOS 27 payload is read with. It runs opposite to the
// Space-index direction, and the scroll direction setting reverses synthetic swipes too.
static double augmented_sign(double sign)
{
    NSNumber *natural = [NSUserDefaults.standardUserDefaults objectForKey:@"com.apple.swipescrolldirection"];
    return (natural ? natural.boolValue : true) ? -sign : sign;
}

// mimi mimiCreateAugmentedDockSwipeEvent. rawSign is the payload's, from augmented_sign.
static CGEventRef mimi_create_event(int phase, double rawSign)
{
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return NULL;

    CGEventSetIntegerValueField(event, kEventTypeField, kEventDockControl);
    CGEventSetIntegerValueField(event, kGestureHIDType, kHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(event, kGestureSwipeMotion, kGestureMotionHorizontal);
    CGEventSetIntegerValueField(event, kGesturePhase, phase);
    CGEventSetIntegerValueField(event, kGesturePhaseAlias, phase);

    CGEventSetDoubleValueField(event, kGestureSwipeProgress, rawSign);
    CGEventSetDoubleValueField(event, kGestureSwipePositionX, kMimiPositionX);
    CGEventSetDoubleValueField(event, kGestureZoomDeltaY, kMimiZoomDeltaY);
    CGEventSetDoubleValueField(event, kSourceUnixProcessIDAlias, (double)mach_absolute_time());

    if (phase == kPhaseEnded) {
        CGEventSetDoubleValueField(event, kGestureSwipeVelocityX, rawSign * kMimiVelocity);
    }

    CGEventRef augmented = dock_swipe_augment(event);
    CFRelease(event);
    return augmented;
}

// mimi's legacy swipe for macOS before 27: began and ended, the sign and velocity in the CGEvent fields.
// Only the last swipe of a switch needs the slow velocity, since only the Space it lands on must redraw; the
// ones before it go at kMimiVelocity and skip their animation, so a multi-Space switch shows one slide.
static bool legacy_post_swipe(double sign, bool last)
{
    double velocity = last ? kLegacyVelocity : kMimiVelocity;
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return false;
    CGEventSetIntegerValueField(event, kEventTypeField, kEventDockControl);
    CGEventSetIntegerValueField(event, kGestureHIDType, kHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(event, kGestureSwipeMotion, kGestureMotionHorizontal);
    CGEventSetDoubleValueField(event, kGestureSwipeProgress, sign);
    CGEventSetDoubleValueField(event, kGestureSwipeVelocityX, sign * velocity);
    CGEventSetIntegerValueField(event, kGesturePhase, kPhaseBegan);
    post_dock_event(event);
    CGEventSetIntegerValueField(event, kGesturePhase, kPhaseEnded);
    post_dock_event(event);
    CFRelease(event);
    return true;
}

// mimi mimiPostAugmentedDockSwipe. sign is +1 toward higher Space indices.
static bool mimi_post_swipe(double sign)
{
    double rawSign = augmented_sign(sign);
    static const int phases[] = {kPhaseBegan, kPhaseChanged, kPhaseEnded};
    for (size_t i = 0; i < sizeof(phases) / sizeof(phases[0]); i++) {
        CGEventRef event = mimi_create_event(phases[i], rawSign);
        if (!event) {
            fprintf(stderr, "switch: failed to build augmented dock swipe event (phase=%d)\n", phases[i]);
            return false;
        }
        post_dock_event(event);
        CFRelease(event);
    }
    return true;
}

static void pump(CFTimeInterval seconds)
{
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

static CGPoint cursor_location(void)
{
    CGEventRef event = CGEventCreate(NULL);
    CGPoint point = CGEventGetLocation(event);
    CFRelease(event);
    return point;
}

static bool cursor_is_on_display(CGDirectDisplayID displayID)
{
    return CGRectContainsPoint(CGDisplayBounds(displayID), cursor_location());
}

// mimi MimiFocusSpaceUsingGesture, augmented branch. mimi pumps the run loop after every step and
// once more for count+1 delays at the end. We post the steps back to back and let Swift poll for the
// landing: with a pause between steps the display lands on each Space on the way, and macOS activates
// the front app there, which puts it into the Cmd-Tab order. Back to back, only the last one counts.
//
// The Dock swipes the display under the cursor; nothing in the event or the IOHID payload names a
// display. So, as mimi, yabai and bobrwm do, warp the cursor to the centre of the target display
// first. Unlike them we put it back afterwards, which costs two extra delays on a cross-display switch.
static bool mimi_post_swipes(double sign, int count, CGDirectDisplayID displayID)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSApplication sharedApplication];  // mimiEnsureApplication
        // After CGWarpMouseCursorPosition macOS drops the user's mouse events for a quarter second
        // unless the suppression interval is zero. yabai sets this at startup for the same reason.
        CGSetLocalEventsSuppressionInterval(0.0);
    });

    bool warp = !cursor_is_on_display(displayID);
    CGPoint restore = cursor_location();
    if (warp) {
        CGRect bounds = CGDisplayBounds(displayID);
        CGWarpMouseCursorPosition(CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)));
        pump(kMimiStepDelay);  // mimi waits this long after its warp too
    }

    bool augmented = requires_augmentation();
    bool posted = true;
    for (int i = 0; i < count && posted; i++) {
        posted = augmented ? mimi_post_swipe(sign) : legacy_post_swipe(sign, i == count - 1);
    }

    if (warp) {
        pump(kMimiStepDelay);  // let the swipes land before the cursor leaves the display
        CGWarpMouseCursorPosition(restore);
        // A warp holds back real mouse movement for a moment; reattaching the mouse ends that.
        CGAssociateMouseAndMouseCursorPosition(true);
    }
    return posted;
}

#pragma clang diagnostic pop

static CGDirectDisplayID display_id_for_uuid(CFStringRef displayUUID)
{
    for (DinkyDisplay *display in dinky_displays()) {
        if ([display.uuid isEqualToString:(__bridge NSString *)displayUUID]) return display.displayID;
    }
    return kCGNullDirectDisplay;
}

bool dinky_switch_to_space_index(int fromIndex, int toIndex, CFStringRef displayUUID)
{
    CGDirectDisplayID displayID = displayUUID ? display_id_for_uuid(displayUUID) : kCGNullDirectDisplay;
    if (displayID == kCGNullDirectDisplay) {
        fprintf(stderr, "switch: no display with UUID %s\n", displayUUID ? [(__bridge NSString *)displayUUID UTF8String] : "(null)");
        return false;
    }
    return mimi_post_swipes(toIndex > fromIndex ? 1.0 : -1.0, abs(toIndex - fromIndex), displayID);
}

// Real Dock swipes, read by the trackpad swipe tap the way iss (github.com/joshuarli/iss) reads them.

CGEventMask dinky_dock_swipe_event_mask(void)
{
    return (1ULL << kEventGesture) | (1ULL << kEventDockControl);
}

bool dinky_read_dock_swipe(CGEventRef event, DinkySwipePhase *phase, bool *vertical, int *direction)
{
    if (CGEventGetIntegerValueField(event, kEventTypeField) != kEventDockControl
        || CGEventGetIntegerValueField(event, kGestureHIDType) != kHIDEventTypeDockSwipe) return false;
    int64_t motion = CGEventGetIntegerValueField(event, kGestureSwipeMotion);
    if (motion != kGestureMotionHorizontal && motion != kGestureMotionVertical) return false;
    *vertical = motion == kGestureMotionVertical;
    *phase = (DinkySwipePhase)CGEventGetIntegerValueField(event, kGesturePhase);
    // The progress while the fingers move; a quick flick may only report a velocity as it ends.
    double value = CGEventGetDoubleValueField(event, kGestureSwipeProgress);
    if (value == 0.0) value = CGEventGetDoubleValueField(event, *vertical ? kGestureSwipeVelocityY : kGestureSwipeVelocityX);
    if (value == 0.0) {
        *direction = 0;
    } else if (requires_augmentation()) {
        // A real swipe's progress runs opposite to the sign a synthetic one is given toward the same Space: with
        // natural scrolling on, positive heads for higher indices. Seen on 27.0.1; augmented_sign is its own inverse.
        *direction = augmented_sign(value > 0.0 ? 1.0 : -1.0) > 0.0 ? -1 : 1;
    } else {
        // Toward higher indices is positive on macOS 26 and negative before it (iss).
        bool reversed = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26;
        *direction = (value > 0.0) == reversed ? 1 : -1;
    }
    // Up and down run the other way round from sideways for the same sign. Seen on 27.0.1.
    if (*vertical) *direction = -*direction;
    return true;
}

bool dinky_is_gesture_event(CGEventRef event)
{
    return CGEventGetIntegerValueField(event, kEventTypeField) == kEventGesture;
}

void dinky_neutralize_dock_swipe(CGEventRef event)
{
    CGEventSetDoubleValueField(event, kGestureSwipeProgress, 0);
    CGEventSetDoubleValueField(event, kGestureSwipeVelocityX, 0);
    CGEventSetDoubleValueField(event, kGestureSwipeVelocityY, 0);
}

bool dinky_dock_swipe_needs_payload(void)
{
    return requires_augmentation();
}

bool dinky_take_own_dock_swipe(void)
{
    // Ones the tap never saw, because it was off or macOS dropped them, would pass real swipes for good.
    if (own_dock_events > 0 && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - own_dock_events_at > 1000000000ULL) {
        own_dock_events = 0;
    }
    if (own_dock_events == 0) return false;
    own_dock_events--;
    return true;
}

void dinky_forget_own_dock_swipes(void)
{
    own_dock_events = 0;
}
