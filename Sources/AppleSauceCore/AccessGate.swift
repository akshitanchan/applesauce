import Foundation

extension ToolError {
    /// The permission is missing or blocked. `fix` is the exact step from `Permission.fix(for:)`.
    public static func permission(_ permission: Permission, state: PermissionState) -> ToolError {
        ToolError(
            .permissionDenied,
            "\(permission.title) access is not allowed (state: \(state.rawValue)).",
            fix: permission.fix(for: state) ?? "Call the 'doctor' tool for details.")
    }

    /// A permission prompt got no answer in time.
    public static func permissionTimeout(_ permission: Permission, seconds: Double) -> ToolError {
        ToolError(
            .permissionTimeout,
            "The \(permission.title) permission prompt got no answer in \(Int(seconds)) seconds.",
            fix:
                "Look for the macOS prompt and click Allow, then try again. If no prompt shows, call the 'doctor' tool."
        )
    }
}

/// Makes sure a permission is granted before a tool reads or writes data.
/// - Granted: returns at once.
/// - Not determined: calls `request` (it shows the macOS prompt) and waits up to `timeout` seconds.
/// - Anything else (denied, write-only, restricted): throws `PERMISSION_DENIED` with the fix.
/// Call it after the input checks, so a bad request never shows a prompt.
public func ensureAccess(
    _ permission: Permission,
    state: @Sendable () -> PermissionState,
    request: @escaping @Sendable () async throws -> Bool,
    timeout: Double = 120
) async throws {
    let current = state()
    if current == .granted { return }
    guard current == .notDetermined else { throw ToolError.permission(permission, state: current) }

    let granted: Bool
    do {
        granted = try await withTimeout(
            seconds: timeout, error: .permissionTimeout(permission, seconds: timeout), request)
    } catch let error as ToolError {
        throw error
    } catch {
        throw ToolError(
            .permissionDenied, "macOS did not grant \(permission.title) access: \(error.localizedDescription)",
            fix: permission.fix(for: .denied) ?? "Call the 'doctor' tool for details.")
    }
    if granted { return }
    let after = state()
    throw ToolError.permission(permission, state: after == .notDetermined ? .denied : after)
}
