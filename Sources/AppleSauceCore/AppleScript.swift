import Foundation

/// Runs AppleScript through `/usr/bin/osascript` with an argv array (no shell).
///
/// The script text goes in on stdin. User values go only as `on run argv` arguments,
/// so a value can never change the script. Example script:
///
///     on run argv
///         tell application "Notes" to get name of folder (item 1 of argv)
///     end run
public enum AppleScript {
    /// Runs `script` and returns its result text (stdout without the last newline).
    /// - Parameters:
    ///   - arguments: values for `argv`. Always pass user text here, never in `script`.
    ///   - permission: the Automation permission the script needs. It makes the permission errors precise.
    ///   - appName: the app the script talks to, for the "app is not running" message. Default: from `permission`.
    ///   - timeout: seconds. After that osascript is ended and the call throws `TIMEOUT`.
    public static func run(
        _ script: String,
        arguments: [String] = [],
        permission: Permission? = nil,
        appName: String? = nil,
        timeout: Double = 30
    ) async throws -> String {
        let result = try await runProcess(
            executable: "/usr/bin/osascript", arguments: ["-"] + arguments, stdin: Data(script.utf8),
            timeout: timeout)
        guard result.status == 0 else {
            throw error(fromStderr: result.stderrText, permission: permission, appName: appName)
        }
        var text = result.stdoutText
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// The error number at the end of an osascript message, for example `-1743` in
    /// `execution error: Not authorized to send Apple events to Mail. (-1743)`.
    /// It reads the last `(number)` in the text. Returns nil when there is none.
    public static func errorNumber(in stderr: String) -> Int? {
        let matches = stderr.matches(of: #/\((-?\d+)\)/#)
        return matches.last.flatMap { Int($0.1) }
    }

    /// Turns osascript stderr into a `ToolError`. It is a pure function, so tests use sample strings.
    /// - -1743: no Automation permission. -1744: the user did not agree yet.
    /// - -600, -609: the app is not running. -1712: the app did not answer in time.
    public static func error(fromStderr stderr: String, permission: Permission? = nil, appName: String? = nil)
        -> ToolError
    {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let app =
            appName
            ?? permission.map { $0.title.replacingOccurrences(of: "Automation: ", with: "") }
            ?? "the app"
        let denied =
            permission?.fix(for: .denied)
            ?? "Open System Settings > Privacy & Security > Automation and turn on applesauce."
        switch errorNumber(in: message) {
        case -1743:
            return ToolError(
                .permissionDenied, "Automation access to \(app) is not allowed (error -1743).", fix: denied)
        case -1744:
            return ToolError(
                .permissionDenied, "Automation access to \(app) needs your consent (error -1744).",
                fix:
                    "Click Allow when macOS asks. If no prompt shows, \(denied.prefix(1).lowercased() + denied.dropFirst())"
            )
        case -600, -609:
            return ToolError(
                .appNotRunning, "\(app) is not running.", fix: "Open \(app), then try again.")
        case -1712:
            return ToolError(
                .timeout, "\(app) did not answer in time (error -1712).",
                fix: "Check that \(app) is not stuck on a dialog. Try a smaller request.")
        default:
            return ToolError(
                .internalError, message.isEmpty ? "osascript failed with no message." : message,
                fix: "Call the 'doctor' tool. If the error stays, report it.")
        }
    }
}
