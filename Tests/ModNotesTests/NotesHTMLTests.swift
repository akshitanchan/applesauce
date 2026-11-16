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
