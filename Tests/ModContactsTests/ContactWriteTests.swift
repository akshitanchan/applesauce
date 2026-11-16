import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModContacts

@Suite struct ContactWriteTests {
    var ada: ContactInfo {
        var info = contactInfo(
            "p1", "Ada Lovelace", organization: "Analytical Engines", emails: ["ada@example.com", "ada@work.example"],
            phones: ["+44 20 7946 0958"])
        info.givenName = "Ada"
        info.familyName = "Lovelace"
        info.jobTitle = "Mathematician"
        info.birthday = "1815-12-10"
        info.addressDetails = [PostalAddress(label: "home", street: "1 Main St", city: "London", country: "UK")]
        return info
    }

    func store(_ edit: (inout FakeContactsStore.State) -> Void = { _ in }) -> FakeContactsStore {
        var state = FakeContactsStore.State()
        state.contacts = [ada, contactInfo("p2", "Grace Hopper", emails: ["grace@navy.example"])]
        state.details = [ada]
        edit(&state)
        return FakeContactsStore(state)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeContactsStore) async throws -> ToolOutput {
        try await ContactsModule(store: store).call(tool, Arguments(args))
    }

    func failure(_ tool: String, _ args: [String: Value], on store: FakeContactsStore) async -> ToolError? {
        do {
            _ = try await run(tool, args, on: store)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    // MARK: pure helpers

    @Test func birthdayParsing() {
        #expect(BirthdayParser.parse("1990-03-05") == Birthday(year: 1990, month: 3, day: 5))
        #expect(BirthdayParser.parse("--03-05") == Birthday(year: nil, month: 3, day: 5))
        #expect(BirthdayParser.parse("--02-29") == Birthday(year: nil, month: 2, day: 29))
        #expect(BirthdayParser.parse("1990-03-05")?.text == "1990-03-05")
        #expect(BirthdayParser.parse("--03-05")?.text == "--03-05")
        for bad in ["1990-02-29", "1990-13-01", "--02-30", "03-05", "1990-3-5", "tomorrow", "--3-5", "0000-01-01"] {
            #expect(BirthdayParser.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func emailAndPhoneRules() {
        #expect(ContactEdit.looksLikeEmail("a@b.co"))
        for bad in ["a", "a@b", "@b.co", "a@@b.co", "a b@c.co", "a@.co", "a@b."] {
            #expect(!ContactEdit.looksLikeEmail(bad), "\(bad)")
        }
        #expect(ContactEdit.sameEmail(" Ada@Example.com", "ada@example.com"))
        #expect(ContactEdit.samePhone("+44 20 7946 0958", "442079460958"))
        #expect(!ContactEdit.samePhone("555-1234", "555-1235"))
    }

    // MARK: create_contact

    @Test func badCreateInputNeverReachesTheStore() async {
        let fake = store { $0.permission = .notDetermined }
        let bad: [[String: Value]] = [
            [:],
            ["given_name": "  "],
            ["job_title": "Boss"],
            ["given_name": "A", "emails": "a@b.co"],
            ["given_name": "A", "emails": ["a@b.co"]],
            ["given_name": "A", "emails": [["label": "work"]]],
            ["given_name": "A", "emails": [["value": "not an email"]]],
            ["given_name": "A", "phones": [["value": "  "]]],
            ["given_name": "A", "addresses": [["label": "home"]]],
            ["given_name": "A", "addresses": "Main St"],
            ["given_name": "A", "birthday": "1990-02-30"],
            ["given_name": "A", "allow_duplicate": "yes"],
        ]
        for args in bad {
            let error = await failure("create_contact", args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func createsAContactWithAllFields() async throws {
        let fake = store()
        let args: [String: Value] = [
            "given_name": " Linus ", "family_name": "Torvalds", "organization": "Linux", "job_title": "Maintainer",
            "emails": [["label": "work", "value": "linus@example.org"]],
            "phones": [["label": "mobile", "value": "+358 40 1234567"], ["value": "555"]],
            "addresses": [
                [
                    "label": "home", "street": "1 Main St", "city": "Portland", "state": "OR",
                    "postal_code": "97201", "country": "USA",
                ]
            ],
            "birthday": "--12-28",
        ]
        let output = try await run("create_contact", args, on: fake)
        let created = try #require(fake.read(\.created))
        #expect(created.givenName == "Linus")
        #expect(created.familyName == "Torvalds")
        #expect(created.jobTitle == "Maintainer")
        #expect(created.emails == [LabeledValue(label: "work", value: "linus@example.org")])
        #expect(created.phones.map(\.value) == ["+358 40 1234567", "555"])
        #expect(created.phones.last?.label == nil)
        #expect(
            created.addresses == [
                PostalAddress(
                    label: "home", street: "1 Main St", city: "Portland", state: "OR", postalCode: "97201",
                    country: "USA")
            ])
        #expect(created.birthday == Birthday(year: nil, month: 12, day: 28))
        #expect(output.text.hasPrefix("Created contact: Linus Torvalds"))
        #expect(output.structured?.objectValue?["id"]?.stringValue == "NEW")
    }

    @Test func organizationAloneIsEnough() async throws {
        let fake = store()
        _ = try await run("create_contact", ["organization": "Acme"], on: fake)
        #expect(fake.read(\.created)?.organization == "Acme")
    }

    @Test func sameFullNameIsRefusedAsAmbiguous() async {
        let fake = store()
        // Case, accents and word order do not matter.
        for args: [String: Value] in [
            ["given_name": "ada", "family_name": "LOVELACE"], ["given_name": "Lovelace", "family_name": "Ada"],
        ] {
            let error = await failure("create_contact", args, on: fake)
            #expect(error?.code == .ambiguous, "\(args)")
            #expect(error?.message.contains("p1") == true)
            #expect(error?.fix?.contains("allow_duplicate") == true)
        }
        #expect(fake.read(\.created) == nil)
    }

    @Test func sameEmailIsRefusedAsAmbiguous() async {
        let fake = store()
        let error = await failure(
            "create_contact",
            ["given_name": "Someone", "emails": [["value": "GRACE@navy.example"]]], on: fake)
        #expect(error?.code == .ambiguous)
        #expect(error?.message.contains("Grace Hopper") == true)
        #expect(fake.read(\.created) == nil)
    }

    @Test func allowDuplicateSkipsTheSearch() async throws {
        let fake = store()
        _ = try await run(
            "create_contact", ["given_name": "Ada", "family_name": "Lovelace", "allow_duplicate": true], on: fake)
        #expect(fake.read(\.created) != nil)
        #expect(!fake.read(\.calls).contains("all"))
    }

    @Test func differentPersonWithSameOrganizationIsNotADuplicate() async throws {
        let fake = store()
        _ = try await run(
            "create_contact",
            ["given_name": "Charles", "family_name": "Babbage", "organization": "Analytical Engines"],
            on: fake)
        #expect(fake.read(\.created) != nil)
    }

    // MARK: update_contact

    @Test func badUpdateInputNeverReachesTheStore() async {
        let fake = store { $0.permission = .notDetermined }
        let bad: [[String: Value]] = [
            [:],
            ["id": "p1"],
            ["id": "p1", "birthday": "soon"],
            ["id": "p1", "add_emails": [["value": "nope"]]],
            ["id": "p1", "remove_emails": [""]],
            ["id": "p1", "remove_phones": "555"],
            ["id": "p1", "addresses": [["label": "home"]]],
        ]
        for args in bad {
            let error = await failure("update_contact", args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func updateReturnsPreviousValuesOfTheChangedFields() async throws {
        let fake = store()
        let output = try await run(
            "update_contact",
            [
                "id": "p1", "job_title": "Countess", "organization": "", "birthday": "",
                "add_emails": [["label": "home", "value": "ada@home.example"]],
                "remove_emails": ["ADA@example.com"], "remove_phones": ["442079460958"],
                "addresses": [],
            ], on: fake)
        let update = try #require(fake.read(\.updated))
        #expect(update.id == "p1")
        #expect(update.patch.jobTitle == "Countess")
        #expect(update.patch.organization == "")
        #expect(update.patch.birthday == .clear)
        #expect(update.patch.givenName == nil)
        #expect(update.patch.addEmails.map(\.value) == ["ada@home.example"])
        #expect(update.patch.removeEmails == ["ADA@example.com"])
        #expect(update.patch.addresses == [])

        let root = try #require(output.structured?.objectValue)
        #expect(root["contact"]?.objectValue?["id"]?.stringValue == "p1")
        let previous = try #require(root["previous"]?.objectValue)
        #expect(previous["job_title"]?.stringValue == "Mathematician")
        #expect(previous["organization"]?.stringValue == "Analytical Engines")
        #expect(previous["birthday"]?.stringValue == "1815-12-10")
        #expect(previous["emails"]?.arrayValue?.count == 2)
        #expect(previous["phones"]?.arrayValue?.count == 1)
        #expect(previous["addresses"]?.arrayValue?.first?.objectValue?["street"]?.stringValue == "1 Main St")
        // Fields that were not in the request are not in 'previous'.
        #expect(previous["given_name"] == nil && previous["family_name"] == nil)
        #expect(output.text.contains("previous"))
    }

    @Test func updateOfAnEmptyFieldReportsAnEmptyPreviousValue() async throws {
        var plain = contactInfo("p9", "Plain Person")
        plain.givenName = "Plain"
        plain.familyName = "Person"
        let fake = store { $0.details = [plain] }
        let output = try await run(
            "update_contact", ["id": "p9", "job_title": "Boss", "birthday": "1990-01-02"], on: fake)
        let previous = try #require(output.structured?.objectValue?["previous"]?.objectValue)
        #expect(previous["job_title"]?.stringValue == "")
        #expect(previous["birthday"]?.stringValue == "")
        #expect(fake.read(\.updated)?.patch.birthday == .set(Birthday(year: 1990, month: 1, day: 2)))
    }

    @Test func unknownIdIsNotFound() async {
        let fake = store()
        let error = await failure("update_contact", ["id": "nope", "job_title": "X"], on: fake)
        #expect(error?.code == .notFound)
        #expect(fake.read(\.updated) == nil)
    }

    @Test func removingAValueTheContactDoesNotHaveIsRefused() async {
        let fake = store()
        let email = await failure("update_contact", ["id": "p1", "remove_emails": ["x@y.zz"]], on: fake)
        #expect(email?.code == .notFound)
        #expect(email?.fix?.contains("ada@example.com") == true)
        let phone = await failure("update_contact", ["id": "p1", "remove_phones": ["999"]], on: fake)
        #expect(phone?.code == .notFound)
        #expect(fake.read(\.updated) == nil)
    }

    @Test func updateCannotLeaveTheContactWithoutAName() async throws {
        var person = contactInfo("p9", "Solo")
        person.givenName = "Solo"
        let fake = store { $0.details = [person] }
        let error = await failure("update_contact", ["id": "p9", "given_name": ""], on: fake)
        #expect(error?.code == .invalidInput)
        #expect(fake.read(\.updated) == nil)
        // An organization keeps the contact valid.
        _ = try await run("update_contact", ["id": "p9", "given_name": "", "organization": "Acme"], on: fake)
        #expect(fake.read(\.updated) != nil)
    }

    @Test func readOnlyRegistryHidesContactWrites() async throws {
        let config = try Config.parse(arguments: ["--read-only"], environment: [:])
        let registry = try Registry(available: [ContactsModule(store: store())], config: config)
        #expect(registry.tools.map(\.name) == ["search_contacts", "get_contact"])
    }
}
