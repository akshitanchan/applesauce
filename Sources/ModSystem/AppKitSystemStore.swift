// The real system store. AppKit exists on macOS only.
#if os(macOS)
import AppKit
import AppleSauceCore
import Foundation
import UserNotifications

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

    /// Inside applesauce.app the notification shows the applesauce icon. A bare binary cannot use the
    /// notification framework, and a missing or denied permission falls back too: then the AppleScript
    /// notification shows the Script Editor icon, but the user still sees it.
    func notify(title: String, message: String, subtitle: String?) async throws {
        if Bundle.main.bundleURL.pathExtension == "app",
            await Self.postWithNotificationCenter(title: title, message: message, subtitle: subtitle)
        {
            return
        }
        _ = try await AppleScript.run(
            Self.notifyScript, arguments: [title, message, subtitle ?? ""], timeout: 15)
    }

    /// True when the notification center took the notification. Without permission yet, it asks in the
    /// background and returns false at once, so this notification uses the fallback and the next ones the icon.
    private static func postWithNotificationCenter(title: String, message: String, subtitle: String?) async -> Bool {
        let allowed = try? await withTimeout(seconds: 5) { try await permission() }
        guard allowed == true else { return false }
        return
            (try? await withTimeout(seconds: 10) { try await add(title: title, message: message, subtitle: subtitle) })
            ?? false
    }

    // The completion handler forms keep non-Sendable notification objects out of the async boundaries.
    private static func permission() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    continuation.resume(returning: true)
                case .notDetermined:
                    // The prompt waits for the user. Do not hold the tool call for it.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    continuation.resume(returning: false)
                default:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func add(title: String, message: String, subtitle: String?) async throws -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        if let subtitle { content.subtitle = subtitle }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        return try await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
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
