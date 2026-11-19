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
        let done = Flag()
        await #expect(throws: ToolError.self) {
            try await withTimeout(seconds: 0.2) { () async -> Int in
                await uncancellableSleep(10, then: done)
                return 1
            }
        }
        // The timeout answered while the work was still running. No fixed time limit: busy CI machines can
        // start the timer late, but never 10 s late.
        #expect(!done.isSet)
    }
}

/// Work that ignores task cancellation, like a stuck Apple Event. It sleeps on its own thread, so it does not
/// hold one of the shared task threads that other tests need.
private func uncancellableSleep(_ seconds: Double, then done: Flag) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: seconds)
            done.set()
            continuation.resume()
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
