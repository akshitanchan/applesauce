import AppleSauceCore
import Foundation
import Testing

@Suite struct AccessGateTests {
    @Test func grantedReturnsWithoutRequest() async throws {
        try await ensureAccess(
            .calendars, state: { .granted },
            request: {
                Issue.record("no request")
                return true
            })
    }

    @Test func deniedThrowsWithFix() async {
        await #expect(throws: ToolError.permission(.reminders, state: .denied)) {
            try await ensureAccess(.reminders, state: { .denied }, request: { true })
        }
        #expect(ToolError.permission(.reminders, state: .denied).fix == Permission.reminders.fix(for: .denied))
        #expect(ToolError.permission(.reminders, state: .denied).code == .permissionDenied)
    }

    @Test func promptTimeoutHasItsOwnCode() async {
        await #expect(throws: ToolError.permissionTimeout(.calendars, seconds: 0.1)) {
            try await ensureAccess(
                .calendars, state: { .notDetermined },
                request: {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return true
                }, timeout: 0.1)
        }
    }
}
