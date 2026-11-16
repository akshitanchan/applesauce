import AppleSauceCore
import Foundation

@testable import ModSystem

/// A system store in memory. It records every call. It never touches the real clipboard, notifications or apps.
final class FakeSystemStore: SystemStore, @unchecked Sendable {
    struct State {
        var clipboard = ClipboardContent(text: nil, types: [])
        var calls: [String] = []
        var notified: (title: String, message: String, subtitle: String?)?
        var opened: [URL] = []
        var delay: Double = 0
        var failure: ToolError?
    }

    private let lock = NSLock()
    private var state: State

    init(_ state: State = State()) {
        self.state = state
    }

    func read<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func write(_ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&state)
    }

    private func pause() async throws {
        let delay = read(\.delay)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let failure = read(\.failure) { throw failure }
    }

    func clipboard() async -> ClipboardContent {
        write { $0.calls.append("clipboard") }
        return read(\.clipboard)
    }

    func setClipboard(_ text: String) async throws {
        write { $0.calls.append("setClipboard") }
        try await pause()
        write { $0.clipboard = ClipboardContent(text: text, types: ["public.utf8-plain-text"]) }
    }

    func notify(title: String, message: String, subtitle: String?) async throws {
        write {
            $0.calls.append("notify")
            $0.notified = (title, message, subtitle)
        }
        try await pause()
    }

    func open(_ url: URL) async throws {
        write {
            $0.calls.append("open")
            $0.opened.append(url)
        }
        try await pause()
    }
}
