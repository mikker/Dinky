import Testing
@testable import dinky

struct SpaceSwitchingTests {
    @Test func macOSSwitchingNeedsNoAdviceWhenFollowingIsOff() {
        #expect(spaceSwitchingStatus(autoSwoosh: true, followsActivation: false) == nil)
    }

    @Test func macOSSwitchingWarnsAboutSlowSwitchWhenFollowingIsOn() throws {
        let status = try #require(spaceSwitchingStatus(autoSwoosh: true, followsActivation: true))
        #expect(status.warning)
        #expect(status.message.contains("macOS's slow switch"))
    }

    @Test func persistentSettingExplainsRecoveryWithAndWithoutFollowing() throws {
        for follows in [false, true] {
            let status = try #require(spaceSwitchingStatus(autoSwoosh: false, followsActivation: follows))
            #expect(status.warning == !follows)
            #expect(status.message.contains("System Settings > Desktop & Dock > Mission Control"))
            #expect(status.message.contains("turn on \"When switching to an application, switch to a Space with open windows\""))
            if follows {
                #expect(status.message.contains("only while running and enabled"))
            } else {
                #expect(status.message.contains("both off"))
            }
        }
    }
}
