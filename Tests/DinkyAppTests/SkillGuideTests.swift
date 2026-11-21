import DinkyCommands
import Testing
@testable import dinky

struct SkillGuideTests {
    @Test func `Guide lists every command with its syntax and description`() {
        for doc in Command.all { #expect(skillGuide.contains("- `\(doc.syntax)`: \(doc.description)"), "\(doc.name)") }
        for row in cliOnlyCommands { #expect(skillGuide.contains("- `\(row.syntax)`: \(row.description)"), "\(row.syntax)") }
    }

    @Test func `Every example in the guide parses`() throws {
        let blocks = skillGuide.components(separatedBy: "```").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        let invocations = blocks.flatMap { $0.components(separatedBy: "dinky ").dropFirst() }
            .map { $0.prefix { $0 != "|" && $0 != ")" && $0 != "\n" }.replacing("\"$id\"", with: "1") }
        #expect(invocations.count >= 10)
        for line in invocations { #expect(throws: Never.self, "\(line)") { try Command.parse(String(line)) } }
    }
}
