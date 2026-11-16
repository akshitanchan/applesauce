import AppleSauceCore
import Foundation
import Testing

@Suite struct TimeoutTests {
    @Test func returnsValueInTime() async throws {
        #expect(try await withTimeout(seconds: 1) { 42 } == 42)
    }

    @Test func passesErrorsThrough() async {
        await #expect(throws: ToolError.invalidInput("x")) {
            try await withTimeout(seconds: 1) { () async throws -> Int in throw ToolError.invalidInput("x") }
        }
    }

    @Test func answersOnTimeWhenWorkBlocks() async throws {
        let start = Date()
        await #expect(throws: ToolError.self) {
            try await withTimeout(seconds: 0.2) { () -> Int in
                blockingSleep(2)  // ignores cancellation
                return 1
            }
        }
        #expect(Date().timeIntervalSince(start) < 1.5)
    }
}

/// A synchronous sleep that ignores task cancellation, like a stuck Apple Event.
private func blockingSleep(_ seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}
