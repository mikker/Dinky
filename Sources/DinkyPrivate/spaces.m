#import "spaces.h"
#import "query.h"
#import "skylight.h"
#import <objc/runtime.h>

// Space creation is a synchronous bridged operation: it returns a result object carrying the new Space ID.
// Its dispatcher is another non-exported static next to the asynchronous one move.m uses,
// found the same way (dinky_skylight_symbol).
// On 27.0 the exported SLSSpaceCreate builds this same operation and calls this same dispatcher.
typedef id (*SLSPerformSynchronousBridgedWindowManagementOperationFn)(id operation);

static SLSPerformSynchronousBridgedWindowManagementOperationFn dinky_sync_dispatcher(void)
{
    static SLSPerformSynchronousBridgedWindowManagementOperationFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dinky_connection();  // make sure SkyLight is loaded and initialised
        fn = (SLSPerformSynchronousBridgedWindowManagementOperationFn)dinky_skylight_symbol(
            "__ZL54_SLSPerformSynchronousBridgedWindowManagementOperationP46SLSSynchronousBridgedWindowManagementOperation");
    });
    return fn;
}

// Runtime encodings on 27.0: initWithOptions:values: is @28@0:8I16@20, the result is a
// SLSBridgedWindowManagementOperationSpaceIDResult with -spaceID (Q16@0:8).
@protocol DinkyBridgedSpaceCreateOperation <NSObject>
- (instancetype)initWithOptions:(uint32_t)options values:(NSDictionary *)values;
@end

@protocol DinkyBridgedSpaceIDResult <NSObject>
- (uint64_t)spaceID;
@end

bool dinky_can_manage_spaces(void)
{
    if (@available(macOS 27.0, *)) return true;
    return false;
}

uint64_t dinky_create_space(CFStringRef displayUUID)
{
    if (!dinky_can_manage_spaces()) {
        fputs("spaces: automatic desktop creation requires macOS 27 or later; use Mission Control\n", stderr);
        return 0;
    }
    SLSPerformSynchronousBridgedWindowManagementOperationFn perform = dinky_sync_dispatcher();
    if (!perform) {
        fputs("spaces: _SLSPerformSynchronousBridgedWindowManagementOperation not found in SkyLight symtab\n", stderr);
        return 0;
    }

    Class cls = objc_getClass("SLSBridgedSpaceCreateOperation");
    if (!cls) {
        fputs("spaces: class SLSBridgedSpaceCreateOperation not found\n", stderr);
        return 0;
    }

    // Keys as bobrwm's createNativeSpace passes them: a user Space (type 0) on the given display.
    NSDictionary *values = @{
        @"type": @(DinkySpaceTypeUser),
        @"Display Identifier": (__bridge NSString *)displayUUID,
    };
    id operation = [(id<DinkyBridgedSpaceCreateOperation>)[cls alloc] initWithOptions:0 values:values];
    if (!operation) {
        fputs("spaces: initWithOptions:values: returned nil\n", stderr);
        return 0;
    }

    id result = perform(operation);
    if (![result respondsToSelector:@selector(spaceID)]) {
        fprintf(stderr, "spaces: create returned %s, not a Space ID result\n", result ? class_getName([result class]) : "nil");
        return 0;
    }
    uint64_t spaceID = [(id<DinkyBridgedSpaceIDResult>)result spaceID];
    if (spaceID == 0) fputs("spaces: create returned Space ID 0\n", stderr);
    return spaceID;
}

// -performWithWMBridgeDelegate hands the operation to AppKit's NSWMWindowCoordinator, which only exists in a
// process with AppKit loaded; from a bare process nothing is removed. See RESULTS.md, "Removing Spaces".
@protocol DinkyBridgedSpaceDestroyOperation <NSObject>
- (instancetype)initWithSpaceID:(uint64_t)spaceID;
- (id)performWithWMBridgeDelegate;
@end

bool dinky_destroy_space(uint64_t spaceID)
{
    if (!dinky_can_manage_spaces()) {
        fputs("spaces: automatic desktop removal requires macOS 27 or later; use Mission Control\n", stderr);
        return false;
    }
    Class cls = objc_getClass("SLSBridgedSpaceDestroyOperation");
    if (!cls) {
        fputs("spaces: class SLSBridgedSpaceDestroyOperation not found\n", stderr);
        return false;
    }
    id operation = [(id<DinkyBridgedSpaceDestroyOperation>)[cls alloc] initWithSpaceID:spaceID];
    if (![operation respondsToSelector:@selector(performWithWMBridgeDelegate)]) {
        fputs("spaces: SLSBridgedSpaceDestroyOperation has no -performWithWMBridgeDelegate\n", stderr);
        return false;
    }
    [(id<DinkyBridgedSpaceDestroyOperation>)operation performWithWMBridgeDelegate];
    return true;
}
