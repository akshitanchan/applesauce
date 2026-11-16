import AppleSauceCore
import Foundation

@testable import ModShortcuts

/// A shortcuts store in memory. It records every call. It never runs a real shortcut.
final class FakeShortcutsStore: ShortcutsStore, @unchecked Sendable {
    struct State {
        var folders: [String: [String]] = [:]
        var shortcuts: [String] = []
        var output: ShortcutOutput = .none
        var runDelay: Double = 0
        var calls: [String] = []
        var ran: (name: String, input: String?)?
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

    func folders() async throws -> [String] {
        write { $0.calls.append("folders") }
        return read { Array($0.folders.keys) }
    }

    func list(folder: String?) async throws -> [String] {
        write { $0.calls.append("list") }
        guard let folder else { return read(\.shortcuts) }
        return read { $0.folders[folder] ?? [] }
    }

    func run(name: String, input: String?) async throws -> ShortcutOutput {
        write {
            $0.calls.append("run")
            $0.ran = (name, input)
        }
        let delay = read(\.runDelay)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return read(\.output)
    }
}
