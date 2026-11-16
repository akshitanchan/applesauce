import Foundation
import MCP

/// The state of every permission, with the step that fixes each missing one.
public struct DoctorReport: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let permission: Permission
        public let title: String
        public let state: PermissionState
        public let neededBy: [String]
        public let fix: String?
    }

    public let version: String
    public let executable: String
    public let readOnly: Bool
    public let modules: [String]
    public let permissions: [Entry]

    public init(registryModules: [String], readOnly: Bool, executable: String, checker: any PermissionChecker) {
        self.version = AppleSauce.version
        self.executable = executable
        self.readOnly = readOnly
        self.modules = registryModules
        self.permissions = Permission.allCases.map { permission in
            let state = checker.state(of: permission)
            return Entry(
                permission: permission, title: permission.title, state: state,
                neededBy: permission.neededBy, fix: permission.fix(for: state))
        }
    }

    public var text: String {
        var lines = [
            "applesauce \(version)",
            "binary: \(executable)",
            "modules: \(modules.isEmpty ? "none" : modules.joined(separator: ", "))\(readOnly ? " (read-only)" : "")",
            "",
            "permissions:",
        ]
        let width = permissions.map(\.title.count).max() ?? 0
        for entry in permissions {
            let mark = entry.state == .granted ? "ok " : "-- "
            let title = entry.title.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(mark)\(title)  \(entry.state.rawValue)  (for \(entry.neededBy.joined(separator: ", ")))")
            if let fix = entry.fix { lines.append("       fix: \(fix)") }
        }
        lines.append("")
        lines.append("Permissions belong to this exact binary. After an update, macOS may ask again.")
        return lines.joined(separator: "\n")
    }
}

/// The `doctor` tool. It is always on and only reads.
public struct DoctorModule: Module {
    public let name = "doctor"
    public let permissions: [Permission] = []
    private let checker: any PermissionChecker
    private let executable: String
    private let modules: [String]
    private let readOnly: Bool

    /// - Parameter modules: names of the enabled feature modules, for the report.
    public init(
        modules: [String], readOnly: Bool,
        checker: any PermissionChecker = SystemPermissionChecker(),
        executable: String = CommandLine.arguments.first ?? "applesauce"
    ) {
        self.modules = modules
        self.readOnly = readOnly
        self.checker = checker
        self.executable = executable
    }

    public var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "doctor",
                description:
                    "Show the applesauce version, enabled modules, and the state of each macOS permission, with the exact step that fixes a missing one. Use it first when a tool fails with PERMISSION_DENIED."
            )
        ]
    }

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        let report = DoctorReport(
            registryModules: modules, readOnly: readOnly, executable: executable, checker: checker)
        return ToolOutput(text: report.text, structured: try Value(report))
    }
}
