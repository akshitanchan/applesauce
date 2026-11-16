import AppleSauceCore
import Testing

@Suite struct ConfigTests {
    @Test func defaultsServeAllModules() throws {
        let config = try Config.parse(arguments: [], environment: [:])
        #expect(config.command == .serve)
        #expect(config.modules == nil)
        #expect(config.isEnabled("mail"))
        #expect(!config.readOnly)
    }

    @Test func flagsSetModulesDisableAndReadOnly() throws {
        let config = try Config.parse(
            arguments: ["doctor", "--modules", "Mail, calendar", "--disable=calendar", "--read-only"],
            environment: [:])
        #expect(config.command == .doctor)
        #expect(config.modules == ["mail", "calendar"])
        #expect(config.isEnabled("mail"))
        #expect(!config.isEnabled("calendar"))
        #expect(!config.isEnabled("notes"))
        #expect(config.readOnly)
    }

    @Test func environmentIsUsedAndFlagsWin() throws {
        let env = ["APPLESAUCE_MODULES": "notes", "APPLESAUCE_READ_ONLY": "true", "APPLESAUCE_DISABLE": "mail"]
        let fromEnv = try Config.parse(arguments: [], environment: env)
        #expect(fromEnv.modules == ["notes"])
        #expect(fromEnv.disabled == ["mail"])
        #expect(fromEnv.readOnly)

        let flagged = try Config.parse(arguments: ["--modules", "calendar"], environment: env)
        #expect(flagged.modules == ["calendar"])
    }

    @Test func emptyEnvironmentValuesMeanNotSet() throws {
        let env = ["APPLESAUCE_MODULES": "", "APPLESAUCE_DISABLE": " ", "APPLESAUCE_READ_ONLY": ""]
        let config = try Config.parse(arguments: [], environment: env)
        #expect(config.modules == nil)
        #expect(config.disabled.isEmpty)
        #expect(!config.readOnly)
        #expect(config.isEnabled("mail"))
    }

    @Test func unresolvedPlaceholdersMeanNotSet() throws {
        let env = [
            "APPLESAUCE_MODULES": "${user_config.modules}", "APPLESAUCE_DISABLE": "${user_config.disable}",
            "APPLESAUCE_READ_ONLY": "${user_config.read_only}",
        ]
        let config = try Config.parse(arguments: [], environment: env)
        #expect(config.modules == nil)
        #expect(config.disabled.isEmpty)
        #expect(!config.readOnly)
        // Real values next to a placeholder still count.
        let mixed = try Config.parse(
            arguments: [], environment: ["APPLESAUCE_MODULES": "mail", "APPLESAUCE_READ_ONLY": "${x}"])
        #expect(mixed.modules == ["mail"])
    }

    @Test func readOnlyEnvFalseValues() throws {
        #expect(try !Config.parse(arguments: [], environment: ["APPLESAUCE_READ_ONLY": "0"]).readOnly)
        #expect(try !Config.parse(arguments: [], environment: ["APPLESAUCE_READ_ONLY": "no"]).readOnly)
    }

    @Test func versionAndHelp() throws {
        #expect(try Config.parse(arguments: ["--version"], environment: [:]).command == .version)
        #expect(try Config.parse(arguments: ["-h"], environment: [:]).command == .help)
    }

    @Test(arguments: [["--bogus"], ["--modules"], ["--modules", "--read-only"], ["serve", "doctor"]])
    func badArgumentsThrow(_ arguments: [String]) {
        #expect(throws: Config.ParseError.self) { try Config.parse(arguments: arguments, environment: [:]) }
    }
}
