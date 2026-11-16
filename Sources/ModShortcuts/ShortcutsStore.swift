import AppleSauceCore
import Foundation

/// What a shortcut gave back. Only text is returned in full.
enum ShortcutOutput: Sendable, Equatable {
    case none
    case text(String, truncated: Bool)
    /// Not text. `type` is a guess from the first bytes, or nil.
    case other(type: String?, bytes: Int)
}

/// The only way the shortcuts module reaches the Shortcuts app.
/// The real store runs `/usr/bin/shortcuts`. Tests use a fake.
protocol ShortcutsStore: Sendable {
    func folders() async throws -> [String]
    /// Names of shortcuts. A nil folder means all shortcuts.
    func list(folder: String?) async throws -> [String]
    /// Runs the shortcut with the exact `name`. It can take a long time.
    func run(name: String, input: String?) async throws -> ShortcutOutput
}
