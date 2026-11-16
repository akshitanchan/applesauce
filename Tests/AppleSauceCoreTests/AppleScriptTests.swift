import AppleSauceCore
import Testing

@Suite struct AppleScriptTests {
    @Test func readsTheErrorNumber() {
        #expect(
            AppleScript.errorNumber(
                in: "execution error: Not authorized to send Apple events to Mail. (-1743)\n") == -1743)
        #expect(AppleScript.errorNumber(in: "Application isn't running. (-600)") == -600)
        #expect(AppleScript.errorNumber(in: "execution error: found (2) items. (-1712)") == -1712)
        #expect(AppleScript.errorNumber(in: "no number here") == nil)
        #expect(AppleScript.errorNumber(in: "") == nil)
    }

    @Test func automationDeniedUsesThePermissionFix() {
        let error = AppleScript.error(
            fromStderr: "0:20: execution error: Not authorized to send Apple events to Mail. (-1743)",
            permission: .automationMail)
        #expect(error.code == .permissionDenied)
        #expect(error.message.contains("Mail"))
        #expect(error.fix == Permission.automationMail.fix(for: .denied))
    }

    @Test func consentNeededIsPermissionDeniedWithAFix() {
        let error = AppleScript.error(
            fromStderr: "execution error: User consent is required. (-1744)", permission: .automationNotes)
        #expect(error.code == .permissionDenied)
        #expect(error.message.contains("consent"))
        #expect(error.fix?.contains("Click Allow") == true)
        #expect(error.fix?.contains("System Settings") == true)
    }

    @Test func appNotRunningSaysOpenTheApp() {
        for text in ["Application isn't running. (-600)", "Connection is invalid. (-609)"] {
            let error = AppleScript.error(fromStderr: text, permission: .automationNotes)
            #expect(error.code == .appNotRunning)
            #expect(error.fix == "Open Notes, then try again.")
        }
        let named = AppleScript.error(fromStderr: "x (-600)", appName: "Mail")
        #expect(named.fix == "Open Mail, then try again.")
    }

    @Test func appleEventTimeoutIsATimeout() {
        let error = AppleScript.error(fromStderr: "AppleEvent timed out. (-1712)", permission: .automationMail)
        #expect(error.code == .timeout)
    }

    @Test func otherErrorsKeepTheMessage() {
        let error = AppleScript.error(fromStderr: "syntax error: Expected end of line. (-2741)\n")
        #expect(error.code == .internalError)
        #expect(error.message == "syntax error: Expected end of line. (-2741)")
        #expect(AppleScript.error(fromStderr: "").code == .internalError)
    }

    @Test func worksWithoutAPermission() {
        let error = AppleScript.error(fromStderr: "x (-1743)")
        #expect(error.code == .permissionDenied)
        #expect(error.fix?.contains("Automation") == true)
    }
}
