import Testing
@testable import DinkyCommands

struct WindowIdentifierQueryTests {
    @Test func identifierIsAvailableInWindowFormats() throws {
        let command = try Command.parse("list-windows --all --format '%{window-id} | %{window-identifier}'")
        guard case .listWindows(let query) = command else {
            Issue.record("Expected a window query")
            return
        }
        #expect(query.format.render([["window-id": "42", "window-identifier": "SettingsWindow"]]) ==
                "42 | SettingsWindow")
        #expect(query.format.render([["window-id": "42", "window-identifier": ""]]) == "42 | ")
    }
}
