import AppleSauceCore
import Foundation
import MCP
import Testing

@Suite struct ISODateTests {
    @Test func parsesDateOnlyAsLocalMidnight() throws {
        let parsed = try #require(ISODate.parse("2026-11-12"))
        #expect(parsed.dateOnly)
        #expect(parsed.date == Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12)))
    }

    @Test func parsesOffsetsAndLocalTime() throws {
        let utc = try #require(ISODate.parse("2026-11-12T09:30:00Z"))
        #expect(!utc.dateOnly)
        #expect(ISODate.parse("2026-11-12T10:30:00+01:00")?.date == utc.date)
        #expect(ISODate.parse("2026-11-12T10:30:00+0100")?.date == utc.date)
        #expect(ISODate.parse("2026-11-12T04:30:00-05:00")?.date == utc.date)
        #expect(ISODate.parse("2026-11-12T09:30:00.250Z")?.date == utc.date)
        #expect(ISODate.parse("2026-11-12T09:30Z")?.date == utc.date)
        let local = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9, minute: 30))
        #expect(ISODate.parse("2026-11-12T09:30:00")?.date == local)
    }

    @Test(arguments: [
        "", "tomorrow", "2026-13-01", "2026-02-30", "2026-11-12T25:00:00", "2026-11-12T10:00:00+25:00", "12/11/2026",
    ])
    func rejectsBadDates(_ text: String) {
        #expect(ISODate.parse(text) == nil)
    }

    @Test func formatsWithOffsetAndRoundTrips() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let date = Date(timeIntervalSince1970: 1_794_000_000)
        let text = ISODate.string(date, timeZone: zone)
        #expect(text.hasSuffix("+01:00"))
        #expect(ISODate.parse(text)?.date == date)
        #expect(ISODate.string(date, timeZone: TimeZone(secondsFromGMT: 0)!).hasSuffix("Z"))
    }

    @Test func argumentsGiveInvalidInputWithExample() {
        let args = Arguments(["d": "soon", "ok": "2026-11-12"])
        #expect(throws: ToolError.self) { try args.date("d") }
        #expect(throws: ToolError.self) { try args.requiredDate("missing") }
        #expect((try? args.date("ok")) != nil)
    }

    @Test func rangeRules() throws {
        let start = try #require(ISODate.parse("2026-11-12"))
        let sameDay = try ISODate.range(start: start, end: start)
        #expect(sameDay.end == ISODate.parse("2026-11-13")?.date)
        #expect(throws: ToolError.self) {
            try ISODate.range(start: start, end: try #require(ISODate.parse("2026-11-11")))
        }
        #expect(throws: ToolError.self) {
            try ISODate.range(start: start, end: try #require(ISODate.parse("2028-01-01")), maxDays: 366)
        }
    }
}
