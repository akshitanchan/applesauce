import AppleSauceCore
import MCP
import Testing

@Suite struct DoctorTests {
    @Test func reportListsEveryPermissionWithFixesOnlyWhenMissing() {
        let checker = FakeChecker(states: [.contacts: .denied, .automationMail: .appNotRunning])
        let report = DoctorReport(
            registryModules: ["mail"], readOnly: true, executable: "/x/applesauce", checker: checker)
        #expect(report.permissions.count == Permission.allCases.count)
        let byPermission = Dictionary(uniqueKeysWithValues: report.permissions.map { ($0.permission, $0) })
        #expect(byPermission[.calendars]?.fix == nil)
        #expect(byPermission[.contacts]?.fix?.contains("Privacy & Security > Contacts") == true)
        #expect(byPermission[.automationMail]?.fix?.contains("Open Mail") == true)
        #expect(report.text.contains("mail (read-only)"))
    }

    @Test func fullDiskAccessFixSaysAddTheBinary() {
        #expect(Permission.fullDiskAccess.fix(for: .denied)?.contains("click +") == true)
    }

    @Test func toolReturnsTextAndStructuredData() async throws {
        let doctor = DoctorModule(modules: [], readOnly: false, checker: FakeChecker())
        let output = try await doctor.call("doctor", Arguments(nil))
        #expect(output.text.hasPrefix("applesauce \(AppleSauce.version)"))
        #expect(output.structured?.objectValue?["permissions"]?.arrayValue?.count == Permission.allCases.count)
    }
}
