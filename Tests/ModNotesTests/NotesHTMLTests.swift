import AppleSauceCore
import Foundation
import Testing

@testable import ModNotes

@Suite struct NotesHTMLTests {
    @Test func escapesTheFourCharacters() {
        #expect(NotesHTML.escape("a & b < c > d \"e\" 'f'") == "a &amp; b &lt; c &gt; d &quot;e&quot; 'f'")
        #expect(NotesHTML.escape("&lt;") == "&amp;lt;")
        #expect(NotesHTML.escape("plain é 日本") == "plain é 日本")
    }

    @Test func noteBodyEscapesTitleAndBody() {
        let html = NotesHTML.noteBody(title: "<b>T</b> & \"q\"", body: "<script>alert(1)</script>\nline & two")
        #expect(
            html
                == "<div><h1>&lt;b&gt;T&lt;/b&gt; &amp; &quot;q&quot;</h1></div><div>&lt;script&gt;alert(1)&lt;/script&gt;<br>line &amp; two</div>"
        )
        #expect(html.contains("<script>") == false)
    }

    @Test func lineBreaksBecomeBr() {
        #expect(NotesHTML.lines("a\nb\r\nc\rd") == "a<br>b<br>c<br>d")
        #expect(NotesHTML.lines("a\n\nb") == "a<br><br>b")
        #expect(NotesHTML.lines("") == "")
    }

    @Test func titleIsOneLineAndBodyIsOptional() {
        #expect(NotesHTML.noteBody(title: "  First\nSecond  ", body: nil) == "<div><h1>First Second</h1></div>")
        #expect(NotesHTML.noteBody(title: "T", body: "") == "<div><h1>T</h1></div>")
    }

    @Test func emptyTitleLeavesNoTitleBlock() {
        #expect(NotesHTML.noteBody(title: "", body: "text") == "<div>text</div>")
        #expect(NotesHTML.noteBody(title: " \n ", body: nil) == "")
    }

    @Test func renameReplacesOnlyTheFirstBlock() {
        let html = "<div><h1>Old &amp; title</h1></div><div>body line<br>two</div><div><br></div>"
        #expect(
            NotesHTML.replacingTitle(in: html, with: "New <title>")
                == "<div><h1>New &lt;title&gt;</h1></div><div>body line<br>two</div><div><br></div>")
        // Formatting that Notes writes for a title typed by hand, with a nested block.
        let styled = "\n<div><b><span style=\"font-size: 24px\">Old</span></b><div>x</div></div><div>rest</div>"
        #expect(NotesHTML.replacingTitle(in: styled, with: "T") == "<div><h1>T</h1></div><div>rest</div>")
        // A note with only a title.
        #expect(NotesHTML.replacingTitle(in: "<div class=\"a\">Old</div>", with: "T") == "<div><h1>T</h1></div>")
        // The title is one line, and it is escaped.
        #expect(NotesHTML.replacingTitle(in: "<div>O</div>", with: "a\nb") == "<div><h1>a b</h1></div>")
    }

    @Test func renameNeedsAFirstBlockThatCloses() {
        #expect(NotesHTML.replacingTitle(in: "", with: "T") == nil)
        #expect(NotesHTML.replacingTitle(in: "plain text", with: "T") == nil)
        #expect(NotesHTML.replacingTitle(in: "<h1>Old</h1><div>x</div>", with: "T") == nil)
        #expect(NotesHTML.replacingTitle(in: "<div>never closed", with: "T") == nil)
        #expect(NotesHTML.replacingTitle(in: "<divider>x</divider>", with: "T") == nil)
    }

    @Test func plainTextLosesItsTitleLine() {
        #expect(NotesHTML.bodyWithoutTitle("Shopping\nmilk\neggs", title: "Shopping") == "milk\neggs")
        #expect(NotesHTML.bodyWithoutTitle("Shopping\r\nmilk", title: "Shopping") == "milk")
        #expect(NotesHTML.bodyWithoutTitle("Shopping", title: "Shopping") == "")
        #expect(NotesHTML.bodyWithoutTitle("Shopping\n\nmilk", title: "Shopping") == "\nmilk")
        // The text does not start with the title: nothing is cut.
        #expect(NotesHTML.bodyWithoutTitle("milk", title: "Shopping") == "milk")
        #expect(NotesHTML.bodyWithoutTitle("milk", title: "") == "milk")
    }

    @Test func appendedTextIsEscapedAsAParagraph() {
        #expect(NotesHTML.fragment("x < y\n\"z\"") == "<div>x &lt; y<br>&quot;z&quot;</div>")
    }

    @Test func sizeLimit() throws {
        try NotesHTML.checkSize(String(repeating: "a", count: NotesHTML.maxBytes))
        #expect(throws: ToolError.self) {
            try NotesHTML.checkSize(String(repeating: "a", count: NotesHTML.maxBytes + 1))
        }
    }
}
