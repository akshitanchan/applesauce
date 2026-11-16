import AppleSauceCore
import Foundation
import Testing

@Suite struct ResolveTests {
    @Test func resolvesByIdOrName() throws {
        struct Item: Identified {
            let id: String
            let title: String
        }
        let items = [Item(id: "1", title: "Work"), Item(id: "2", title: "work"), Item(id: "3", title: "Home")]
        #expect(try resolveByIdOrName("home", kind: "list", in: items).id == "3")
        #expect(try resolveByIdOrName("2", kind: "list", in: items).id == "2")
        #expect(throws: ToolError.self) { try resolveByIdOrName("WORK", kind: "list", in: items) }
        #expect(throws: ToolError.self) { try resolveByIdOrName("none", kind: "list", in: items) }
    }
}
