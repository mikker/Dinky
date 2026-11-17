import DinkyConfig

/// The destructive boundary: use fresh observations, confirm departure, then validate again immediately
/// before destruction. A posted swipe is not an observed landing. Unknown or vanished displays fail closed.
struct SpaceRemoval {
    var snapshot: () -> [PlanDisplay]
    var destinations: (String) -> [UInt64]
    var switchTo: (UInt64, String) -> Bool
    var wait: (() -> Bool) -> Bool
    var canRemove: (UInt64) -> Bool
    var destroy: (UInt64) -> Bool

    func remove(_ space: UInt64) -> Bool {
        guard let display = snapshot().first(where: { $0.spaces.contains(space) }),
              display.spaces.contains(display.current), canRemove(space) else { return false }
        if display.current == space {
            guard let target = destinations(display.uuid).first(where: { $0 != space && display.spaces.contains($0) }),
                  switchTo(target, display.uuid),
                  wait({ snapshot().contains { $0.uuid == display.uuid && $0.spaces.contains(target) && $0.current == target } }) else {
                return false
            }
        }
        guard let fresh = snapshot().first(where: { $0.uuid == display.uuid && $0.spaces.contains(space) }),
              fresh.current != space, fresh.spaces.contains(fresh.current), canRemove(space) else { return false }
        return destroy(space)
    }
}
