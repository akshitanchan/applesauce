import AppleSauceCore
import Foundation
import MCP
import ModCalendar
import ModContacts
import ModMail
import ModNotes
import ModReminders
import ModShortcuts
import ModSpotlight
import ModSystem

TCCBootstrap.disclaimIfNeeded()

let help = """
    applesauce \(AppleSauce.version): an MCP server for the Apple apps on your Mac.

    usage:
      applesauce [serve] [options]   run the MCP server on stdin and stdout (default)
      applesauce doctor [options]    show the state of each macOS permission and how to fix it
      applesauce --version
      applesauce --help

    options:
      --modules a,b    turn on only these modules
      --disable a,b    turn off these modules
      --read-only      hide every tool that changes data

    environment (flags win):
      APPLESAUCE_MODULES, APPLESAUCE_DISABLE, APPLESAUCE_READ_ONLY=1
    """

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("applesauce: \(message)\n".utf8))
    exit(code)
}

let config: Config
do {
    config = try Config.parse(
        arguments: Array(CommandLine.arguments.dropFirst()),
        environment: ProcessInfo.processInfo.environment)
} catch {
    fail("\(error)", code: 2)
}

switch config.command {
case .version:
    print(AppleSauce.version)
    exit(0)
case .help:
    print(help)
    exit(0)
case .serve, .doctor:
    break
}

#if os(macOS)
let features: [any Module] = [
    CalendarModule(), RemindersModule(), MailModule(), NotesModule(), ContactsModule(), ShortcutsModule(),
    SpotlightModule(), SystemModule(),
]
#else
// Other systems list the same tools, and every call answers UNSUPPORTED_PLATFORM.
let features: [any Module] = [
    MacOnlyModule(
        name: CalendarModule.moduleName, tools: CalendarModule.toolSpecs,
        permissions: CalendarModule.requiredPermissions),
    MacOnlyModule(
        name: RemindersModule.moduleName, tools: RemindersModule.toolSpecs,
        permissions: RemindersModule.requiredPermissions),
    MacOnlyModule(
        name: MailModule.moduleName, tools: MailModule.toolSpecs, permissions: MailModule.requiredPermissions),
    MacOnlyModule(
        name: NotesModule.moduleName, tools: NotesModule.toolSpecs, permissions: NotesModule.requiredPermissions),
    MacOnlyModule(
        name: ContactsModule.moduleName, tools: ContactsModule.toolSpecs,
        permissions: ContactsModule.requiredPermissions),
    MacOnlyModule(
        name: ShortcutsModule.moduleName, tools: ShortcutsModule.toolSpecs,
        permissions: ShortcutsModule.requiredPermissions),
    MacOnlyModule(
        name: SpotlightModule.moduleName, tools: SpotlightModule.toolSpecs,
        permissions: SpotlightModule.requiredPermissions),
    MacOnlyModule(
        name: SystemModule.moduleName, tools: SystemModule.toolSpecs, permissions: SystemModule.requiredPermissions),
]
#endif
let executable = TCCBootstrap.executablePath ?? CommandLine.arguments[0]
let doctor = DoctorModule(
    modules: features.map(\.name).filter(config.isEnabled),
    readOnly: config.readOnly, executable: executable)

let registry: Registry
do {
    registry = try Registry(available: features, alwaysOn: [doctor], config: config)
} catch {
    fail("\(error)", code: 2)
}

if config.command == .doctor {
    let output = try await doctor.call("doctor", Arguments(nil))
    print(output.text)
    exit(0)
}

let server = await ServerFactory.make(registry: registry)
do {
    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
} catch {
    fail("server stopped: \(error)", code: 1)
}
