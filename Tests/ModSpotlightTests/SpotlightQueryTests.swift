import Foundation
import Testing

@testable import ModSpotlight

@Suite struct SpotlightQueryTests {
    @Test func escapesQuotesAndBackslashes() {
        #expect(SpotlightQuery.escape(#"say "hi""#) == #"say \"hi\""#)
        #expect(SpotlightQuery.escape(#"a\b"#) == #"a\\b"#)
        #expect(SpotlightQuery.escape(#"\""#) == #"\\\""#)
        #expect(SpotlightQuery.escape("line1\nline2") == "line1 line2")
        #expect(SpotlightQuery.escape("plain") == "plain")
    }

    @Test func plainTextGoesAsItIs() {
        #expect(SpotlightQuery.build(text: "  budget 2026 ", kind: nil) == "budget 2026")
        #expect(SpotlightQuery.build(text: #"kMDItemFSName == "x""#, kind: nil) == #"kMDItemFSName == "x""#)
    }

    @Test func kindBuildsAFilterWithEscapedWords() {
        let query = SpotlightQuery.build(text: #"tax "2026""#, kind: .pdf)
        #expect(
            query
                == #"(kMDItemDisplayName == "*tax*"cd || kMDItemTextContent == "tax*"cd) && "#
                + #"(kMDItemDisplayName == "*\"2026\"*"cd || kMDItemTextContent == "\"2026\"*"cd) && "#
                + #"(kMDItemContentTypeTree == "com.adobe.pdf")"#)
    }

    @Test func aQuoteInTheTextCannotBreakOutOfTheValue() {
        let query = SpotlightQuery.build(text: #"x" || kMDItemFSName == "*"#, kind: .text)
        #expect(query.contains(#"kMDItemDisplayName == "*x\"*"cd"#))
        #expect(query.contains(#"kMDItemDisplayName == "*\"**"cd"#))
        // Remove each escaped pair. The quotes that are left open and close the values:
        // 2 for each name match, 2 for each content match, 2 for the type.
        let words = 5
        let unescaped = query.replacing(#/\\./#, with: "")
        #expect(unescaped.filter { $0 == "\"" }.count == words * 4 + 2)
        #expect(query.hasSuffix(#"(kMDItemContentTypeTree == "public.plain-text")"#))
    }

    @Test func textStartingWithDashGetsTheBuiltForm() {
        let query = SpotlightQuery.build(text: "-onlyin /", kind: nil)
        #expect(!query.hasPrefix("-"))
        #expect(query.contains(#"kMDItemDisplayName == "*-onlyin*"cd"#))
    }

    @Test func everyKindHasTypes() {
        for kind in SpotlightKind.allCases {
            let query = SpotlightQuery.build(text: "x", kind: kind)
            #expect(!kind.contentTypes.isEmpty)
            #expect(query.contains("kMDItemContentTypeTree == \"\(kind.contentTypes[0])\""))
        }
        #expect(
            SpotlightKind.allCases.map(\.rawValue).sorted() == [
                "audio", "document", "folder", "image", "pdf", "presentation", "spreadsheet", "text", "video",
            ])
    }
}
