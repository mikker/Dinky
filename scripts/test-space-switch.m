#define CGEventPost capture_event_post
#import "../Sources/DinkyPrivate/switch.m"
#undef CGEventPost

#include <assert.h>

static CGEventRef captured[8];
static size_t captured_count;

void capture_event_post(CGEventTapLocation location, CGEventRef event)
{
    (void)location;
    assert(captured_count < sizeof(captured) / sizeof(captured[0]));
    captured[captured_count++] = CGEventCreateCopy(event);
}

NSArray<DinkyDisplay *> *dinky_displays(void) { return @[]; }

static void clear_events(void)
{
    for (size_t i = 0; i < captured_count; i++) CFRelease(captured[i]);
    captured_count = 0;
}

static void test_legacy(double sign)
{
    assert(mimi_post_legacy_swipe(sign));
    assert(captured_count == 2);
    const int phases[] = {kPhaseBegan, kPhaseEnded};
    for (size_t i = 0; i < 2; i++) {
        CGEventRef event = captured[i];
        assert(CGEventGetIntegerValueField(event, kEventTypeField) == kEventDockControl);
        assert(CGEventGetIntegerValueField(event, kGestureHIDType) == kHIDEventTypeDockSwipe);
        assert(CGEventGetIntegerValueField(event, kGestureSwipeMotion) == kGestureMotionHorizontal);
        assert(CGEventGetIntegerValueField(event, kGesturePhase) == phases[i]);
        assert(CGEventGetDoubleValueField(event, kGestureSwipeProgress) == sign);
        assert(CGEventGetDoubleValueField(event, kGestureSwipeVelocityX) == sign * kMimiVelocity);
    }
    clear_events();
}

static void test_augmented(double sign)
{
    const int phases[] = {kPhaseBegan, kPhaseChanged, kPhaseEnded};
    for (size_t i = 0; i < 3; i++) {
        CGEventRef event = mimi_create_event(phases[i], sign);
        assert(event);
        capture_event_post(kCGSessionEventTap, event);
        CFRelease(event);
    }
    assert(captured_count == 3);
    for (size_t i = 0; i < 3; i++) {
        CGEventRef event = captured[i];
        assert(CGEventGetIntegerValueField(event, kEventTypeField) == kEventDockControl);
        assert(CGEventGetIntegerValueField(event, kGestureHIDType) == kHIDEventTypeDockSwipe);
        assert(CGEventGetIntegerValueField(event, kGestureSwipeMotion) == kGestureMotionHorizontal);
        assert(CGEventGetIntegerValueField(event, kGesturePhase) == phases[i]);
        assert(CGEventGetIntegerValueField(event, kGesturePhaseAlias) == phases[i]);
        assert(CGEventGetDoubleValueField(event, kGestureSwipeProgress) == -sign);
        assert(CGEventGetDoubleValueField(event, kGestureZoomDeltaY) == kMimiZoomDeltaY);
        assert(CGEventGetDoubleValueField(event, kGestureSwipeVelocityX) == (i == 2 ? -sign * kMimiVelocity : 0.0));

        size_t payloadLength = 0;
        uint8_t *payload = build_iohid_payload(event, &payloadLength);
        assert(payload);
        assert(payloadLength == sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData) +
               (i == 2 ? sizeof(IOHIDVelocityEventData) : 0));
        IOHIDSystemQueueElementHeader header;
        IOHIDFluidTouchGestureData fluid;
        memcpy(&header, payload, sizeof(header));
        memcpy(&fluid, payload + sizeof(header), sizeof(fluid));
        assert(header.eventCount == (i == 2 ? 2 : 1));
        assert(fluid.base.options == ((uint32_t)phases[i] << 24));
        assert(fluid.swipeMask == 0);
        assert(fluid.gestureMotion == kGestureMotionHorizontal);
        assert(fluid.gestureFlavor == kIOHIDGestureFlavorDockPrimary);
        assert(fluid.swipeProgress == fixed_1616(-sign));
        if (i == 2) {
            IOHIDVelocityEventData velocity;
            memcpy(&velocity, payload + sizeof(header) + sizeof(fluid), sizeof(velocity));
            assert(velocity.velocityX == fixed_1616(-sign * kMimiVelocity));
        }
        free(payload);
    }
    clear_events();
}

int main(void)
{
    const NSInteger versions[] = {14, 15, 16, 26, 27, 28};
    for (size_t v = 0; v < sizeof(versions) / sizeof(versions[0]); v++) {
        const bool expected_legacy = versions[v] == 15;
        assert(uses_legacy_swipe_for_major_version(versions[v]) == expected_legacy);
        for (int direction = 0; direction < 2; direction++) {
            double sign = direction == 0 ? 1.0 : -1.0;
            assert(mimi_post_swipe_for_major_version(sign, versions[v]));
            if (expected_legacy) {
                assert(captured_count == 2);
                assert(CGEventGetIntegerValueField(captured[0], kGesturePhase) == kPhaseBegan);
                assert(CGEventGetIntegerValueField(captured[1], kGesturePhase) == kPhaseEnded);
                for (size_t i = 0; i < captured_count; i++) {
                    assert(CGEventGetDoubleValueField(captured[i], kGestureSwipeProgress) == sign);
                    assert(CGEventGetDoubleValueField(captured[i], kGestureSwipeVelocityX) == sign * kMimiVelocity);
                }
                clear_events();
            } else {
                assert(captured_count == 3);
                const int phases[] = {kPhaseBegan, kPhaseChanged, kPhaseEnded};
                for (size_t i = 0; i < captured_count; i++) {
                    assert(CGEventGetIntegerValueField(captured[i], kGesturePhase) == phases[i]);
                    assert(CGEventGetDoubleValueField(captured[i], kGestureSwipeProgress) == -sign);
                }
                clear_events();
            }
        }
    }
    test_legacy(1.0); test_legacy(-1.0);
    test_augmented(1.0); test_augmented(-1.0);
    puts("space-switch regression tests passed");
    return 0;
}
