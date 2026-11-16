import MCP
import Testing

@testable import AppleSauceCore

@Suite struct AttachmentPickTests {
    func pick(_ raw: [String: Value]) throws -> AttachmentPick { try AttachmentPick(Arguments(raw)) }

    @Test func readsNameOrIndex() throws {
        #expect(try pick(["name": "a b.pdf"]) == .name("a b.pdf"))
        #expect(try pick(["index": 3]) == .index(3))
        #expect(try pick(["index": 2.0]) == .index(2))
        // The name keeps its spaces: they can be part of the file name.
        #expect(try pick(["name": " x "]) == .name(" x "))
    }

    @Test func refusesBadCombinations() {
        let bad: [[String: Value]] = [
            [:], ["name": "a", "index": 1], ["index": 0], ["index": -2], ["index": "1"], ["name": ""],
            ["name": 4], ["name": "a\0b"],
        ]
        for raw in bad {
            do {
                _ = try pick(raw)
                Issue.record("expected an error for \(raw)")
            } catch let error as ToolError {
                #expect(error.code == .invalidInput, "\(raw)")
            } catch {
                Issue.record("wrong error type")
            }
        }
    }

    @Test func resolvesInANoteOrAMessage() throws {
        let names = ["a.png", "A.PNG", "b.pdf", "b.pdf"]
        #expect(try AttachmentPick.name("a.png").resolve(in: names, owner: "note") == 0)
        #expect(try AttachmentPick.name("B.PDF").resolve(in: ["x", "b.pdf"], owner: "note") == 1)
        #expect(try AttachmentPick.index(3).resolve(in: names, owner: "note") == 2)
        func failure(_ pick: AttachmentPick, _ names: [String]) -> ToolError? {
            do {
                _ = try pick.resolve(in: names, owner: "note")
                return nil
            } catch {
                return error as? ToolError
            }
        }
        #expect(failure(.index(5), names)?.message.contains("The note has 4 attachments") == true)
        #expect(failure(.name("zip"), names)?.code == .notFound)
        #expect(failure(.name("b.pdf"), names)?.code == .ambiguous)
        #expect(failure(.index(1), [])?.message == "The note has no attachments.")
    }
}
