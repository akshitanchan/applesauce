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
            try await withTimeout(seconds: 0.2) { () async -> Int in
                await uncancellableSleep(2)
                return 1
            }
        }
        #expect(Date().timeIntervalSince(start) < 1.5)
    }
}

/// Work that ignores task cancellation, like a stuck Apple Event. It sleeps on its own thread, so it does not
/// hold one of the shared task threads that other tests need.
private func uncancellableSleep(_ seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: seconds)
            continuation.resume()
        }
    }
}
