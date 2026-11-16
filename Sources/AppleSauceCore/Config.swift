import Foundation

/// Command line and environment settings.
/// Flags win over environment variables.
public struct Config: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case serve, doctor, version, help
    }

    public var command: Command = .serve
    /// nil means all modules.
    public var modules: Set<String>?
    public var disabled: Set<String> = []
    public var readOnly = false

    public init() {}

    public func isEnabled(_ module: String) -> Bool {
        (modules?.contains(module) ?? true) && !disabled.contains(module)
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static func parse(arguments: [String], environment: [String: String]) throws -> Config {
        var config = Config()
        // An empty value means "not set". A bundle host can pass an empty string for a blank setting.
        // A value that still starts with `${` is a placeholder that the host did not fill in. That also means "not set".
        func setting(_ key: String) -> String? {
            guard let value = environment[key], !value.trimmingCharacters(in: .whitespaces).hasPrefix("${") else {
                return nil
            }
            return value
        }
        if let list = setting("APPLESAUCE_MODULES"), !names(list).isEmpty { config.modules = names(list) }
        if let list = setting("APPLESAUCE_DISABLE") { config.disabled = names(list) }
        if let flag = setting("APPLESAUCE_READ_ONLY") { config.readOnly = truthy(flag) }

        var rest = arguments[...]
        var sawCommand = false
        while let arg = rest.popFirst() {
            let (key, inline) = splitFlag(arg)
            switch key {
            case "serve", "doctor":
                guard !sawCommand else { throw ParseError(description: "Only one command is allowed.") }
                sawCommand = true
                config.command = key == "serve" ? .serve : .doctor
            case "--version", "-v", "version":
                config.command = .version
            case "--help", "-h", "help":
                config.command = .help
            case "--read-only":
                config.readOnly = true
            case "--modules", "--disable":
                guard let value = inline ?? rest.popFirst(), !value.hasPrefix("--") else {
                    throw ParseError(
                        description: "\(key) needs a comma-separated list, for example \(key) calendar,mail.")
                }
                if key == "--modules" { config.modules = names(value) } else { config.disabled = names(value) }
            default:
                throw ParseError(description: "Unknown argument '\(arg)'. Run applesauce --help.")
            }
        }
        return config
    }

    private static func splitFlag(_ arg: String) -> (String, String?) {
        guard arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") else { return (arg, nil) }
        return (String(arg[..<eq]), String(arg[arg.index(after: eq)...]))
    }

    private static func names(_ list: String) -> Set<String> {
        Set(
            list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter {
                !$0.isEmpty
            })
    }

    private static func truthy(_ value: String) -> Bool {
        ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
