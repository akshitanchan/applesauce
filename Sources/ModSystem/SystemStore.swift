import AppleSauceCore
import Foundation

/// What the clipboard holds.
struct ClipboardContent: Sendable, Equatable {
    /// The text, or nil when the clipboard holds no text.
    let text: String?
    /// Type identifiers on the clipboard, for example `public.png`. Used to say what is there instead of text.
    let types: [String]
}

/// The only way the system module reaches the clipboard, notifications and the default apps.
/// The real store uses AppKit and the AppleScript runner. Tests use a fake.
protocol SystemStore: Sendable {
    func clipboard() async -> ClipboardContent
    func setClipboard(_ text: String) async throws
    func notify(title: String?, message: String, subtitle: String?) async throws
    /// Opens a URL or a file in its default app.
    func open(_ url: URL) async throws
}
