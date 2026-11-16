// The real system store. AppKit exists on macOS only.
#if os(macOS)
import AppKit
import AppleSauceCore
import Foundation

/// The real system store. It uses `NSPasteboard`, `NSWorkspace` and the AppleScript runner.
actor AppKitSystemStore: SystemStore {
    func clipboard() async -> ClipboardContent {
        let pasteboard = NSPasteboard.general
        return ClipboardContent(
            text: pasteboard.string(forType: .string), types: (pasteboard.types ?? []).map(\.rawValue))
    }

    func setClipboard(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw ToolError(
                .internalError, "macOS did not accept the text for the clipboard.",
                fix: "Try again. If this stays, report it.")
        }
    }

    /// The script gets the values as `argv` items. They are never put into the script text.
    static let notifyScript = """
        on run argv
            set theTitle to item 1 of argv
            set theMessage to item 2 of argv
            set theSubtitle to item 3 of argv
            if theSubtitle is "" then
                display notification theMessage with title theTitle
            else
                display notification theMessage with title theTitle subtitle theSubtitle
            end if
        end run
        """

    func notify(title: String, message: String, subtitle: String?) async throws {
        _ = try await AppleScript.run(
            Self.notifyScript, arguments: [title, message, subtitle ?? ""], timeout: 15)
    }

    func open(_ url: URL) async throws {
        guard NSWorkspace.shared.open(url) else {
            throw ToolError(
                .internalError, "macOS could not open \(url.isFileURL ? url.path : url.absoluteString).",
                fix: "Check that an app is set to open this kind of item.")
        }
    }
}
#endif
