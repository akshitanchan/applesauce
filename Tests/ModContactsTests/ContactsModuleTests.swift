import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModContacts

@Suite struct ContactsModuleTests {
    let ada = contactInfo(
        "p1", "Ada Lovelace", organization: "Analytical Engines", emails: ["ada@example.com"],
        phones: ["+44 20 7946 0958"])
    let grace = contactInfo(
        "p2", "Grace Hopper", organization: "Navy", emails: ["grace@navy.example"], phones: ["(555) 123-4567"])
    let renee = contactInfo("p3", "René Müller", phones: [])

    func store(_ edit: (inout FakeContactsStore.State) -> Void = { _ in }) -> FakeContactsStore {
        var state = FakeContactsStore.State()
        state.contacts = [grace, ada, renee]
        edit(&state)
        return FakeContactsStore(state)
    }

    func module(_ store: FakeContactsStore, permissionTimeout: Double = 120, backendTimeout: Double = 30)
        -> ContactsModule
    {
        ContactsModule(store: store, permissionTimeout: permissionTimeout, backendTimeout: backendTimeout)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeContactsStore) async throws -> ToolOutput {
        try await module(store).call(tool, Arguments(args))
    }

    func failure(
        _ tool: String, _ args: [String: Value], on store: FakeContactsStore, using module: ContactsModule? = nil
    ) async -> ToolError? {
        do {
            _ = try await (module ?? self.module(store)).call(tool, Arguments(args))
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func names(_ output: ToolOutput) -> [String] {
        output.structured?.objectValue?["contacts"]?.arrayValue?.compactMap {
            $0.objectValue?["name"]?.stringValue
        } ?? []
    }

    // MARK: tools

    @Test func toolNamesAndFlags() {
        let tools = module(store()).tools
        #expect(tools.map(\.tool.name) == ["search_contacts", "get_contact", "create_contact", "update_contact"])
        #expect(tools.filter(\.isWrite).map(\.tool.name) == ["create_contact", "update_contact"])
        #expect(tools.allSatisfy { $0.tool.annotations.destructiveHint != true })
    }

    // MARK: input checks

    @Test func badInputNeverReachesTheStore() async {
        let fake = store { $0.permission = .notDetermined }
        let bad: [(String, [String: Value])] = [
            ("search_contacts", [:]),
            ("search_contacts", ["query": ""]),
            ("search_contacts", ["query": "   "]),
            ("search_contacts", ["query": 5]),
            ("search_contacts", ["query": "a", "limit": 0]),
            ("search_contacts", ["query": "a", "limit": 201]),
            ("get_contact", [:]),
            ("get_contact", ["id": " "]),
        ]
        for (tool, args) in bad {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .invalidInput, "\(tool) \(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    // MARK: permissions

    @Test(arguments: [PermissionState.denied, .restricted, .limited])
    func blockedPermissionGivesFix(_ state: PermissionState) async {
        let fake = store { $0.permission = state }
        let error = await failure("search_contacts", ["query": "ada"], on: fake)
        #expect(error?.code == .permissionDenied)
        #expect(error?.fix == Permission.contacts.fix(for: state))
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func notDeterminedAsksOnceThenRuns() async throws {
        let fake = store { $0.permission = .notDetermined }
        _ = try await run("search_contacts", ["query": "ada"], on: fake)
        #expect(fake.read(\.calls) == ["request", "all"])
    }

    @Test func unansweredPromptGivesPermissionTimeout() async {
        let fake = store {
            $0.permission = .notDetermined
            $0.requestDelay = 5
        }
        let error = await failure(
            "search_contacts", ["query": "ada"], on: fake, using: module(fake, permissionTimeout: 0.1))
        #expect(error?.code == .permissionTimeout)
    }

    @Test func slowBackendGivesTimeout() async {
        let fake = store { $0.listDelay = 5 }
        let error = await failure(
            "search_contacts", ["query": "ada"], on: fake, using: module(fake, backendTimeout: 0.1))
        #expect(error?.code == .timeout)
    }

    // MARK: search

    @Test func searchMatchesNameOrganizationEmailAndPhone() async throws {
        let fake = store()
        for (query, expected) in [
            ("lovelace", ["Ada Lovelace"]),
            ("ADA", ["Ada Lovelace"]),
            ("navy", ["Grace Hopper"]),
            ("grace@navy", ["Grace Hopper"]),
            ("rene muller", ["René Müller"]),
            ("lovelace ada", ["Ada Lovelace"]),
            ("555 123", ["Grace Hopper"]),
            ("+44 20", ["Ada Lovelace"]),
            ("7946", ["Ada Lovelace"]),
            ("nobody", []),
        ] {
            let output = try await run("search_contacts", ["query": .string(query)], on: fake)
            #expect(names(output) == expected, "\(query)")
        }
    }

    @Test func searchSortsByNameAndSaysWhenEmpty() async throws {
        let fake = store()
        let output = try await run("search_contacts", ["query": "e"], on: fake)
        #expect(names(output) == ["Ada Lovelace", "Grace Hopper", "René Müller"])
        let none = try await run("search_contacts", ["query": "zzz"], on: fake)
        #expect(none.text == "0 contacts.")
    }

    @Test func limitCutsAndReportsTotal() async throws {
        let many = (1...30).map { contactInfo("id\($0)", String(format: "Pat %02d", $0)) }
        let fake = store { $0.contacts = many }
        let output = try await run("search_contacts", ["query": "pat"], on: fake)
        #expect(names(output).count == 25)
        #expect(output.structured?.objectValue?["total"]?.intValue == 30)
        #expect(output.structured?.objectValue?["truncated"]?.boolValue == true)
        #expect(output.text.contains("Showing 25 of 30"))
        let small = try await run("search_contacts", ["query": "pat", "limit": 3], on: fake)
        #expect(names(small) == ["Pat 01", "Pat 02", "Pat 03"])
        let max = try await run("search_contacts", ["query": "pat", "limit": 200], on: fake)
        #expect(names(max).count == 30)
        #expect(max.structured?.objectValue?["truncated"]?.boolValue == false)
    }

    @Test func searchOutputHasLabelsButNoNote() async throws {
        let output = try await run("search_contacts", ["query": "ada"], on: store())
        let first = try #require(output.structured?.objectValue?["contacts"]?.arrayValue?.first?.objectValue)
        #expect(first["emails"]?.arrayValue?.first?.objectValue?["label"]?.stringValue == "work")
        #expect(first["phones"]?.arrayValue?.first?.objectValue?["value"]?.stringValue == "+44 20 7946 0958")
        #expect(first["note"] == nil)
        #expect(output.text.contains("work: ada@example.com"))
    }

    // MARK: matcher

    @Test func phoneQueryNeedsThreeDigitsAndPhoneCharactersOnly() {
        #expect(ContactMatcher.phoneDigits("(555) 123-4567") == "5551234567")
        #expect(ContactMatcher.phoneDigits("+44") == nil)
        #expect(ContactMatcher.phoneDigits("12") == nil)
        #expect(ContactMatcher.phoneDigits("ab 123") == nil)
        #expect(!ContactMatcher.matches(ada, query: ""))
    }

    // MARK: get_contact

    @Test func getContactReturnsDetails() async throws {
        var full = ada
        full.jobTitle = "Mathematician"
        full.birthday = "1815-12-10"
        full.addresses = [LabeledValue(label: "home", value: "1 Main St, London")]
        let fake = store { $0.details = [full] }
        let output = try await run("get_contact", ["id": "p1"], on: fake)
        let object = try #require(output.structured?.objectValue)
        #expect(object["job_title"]?.stringValue == "Mathematician")
        #expect(object["birthday"]?.stringValue == "1815-12-10")
        #expect(object["addresses"]?.arrayValue?.count == 1)
        #expect(object["note"] == nil)
        #expect(output.text.contains("birthday 1815-12-10"))
    }

    @Test func unknownIdIsNotFound() async {
        let fake = store()
        let error = await failure("get_contact", ["id": "nope"], on: fake)
        #expect(error?.code == .notFound)
        #expect(error?.fix?.contains("search_contacts") == true)
    }
}
