import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModContacts

@Suite struct ContactDeleteTests {
    var ada: ContactInfo {
        var info = contactInfo(
            "p1", "Ada Lovelace", organization: "Analytical Engines", emails: ["ada@example.com", "ada@work.example"],
            phones: ["+44 20 7946 0958"])
        info.givenName = "Ada"
        info.familyName = "Lovelace"
        info.jobTitle = "Mathematician"
        info.birthday = "1815-12-10"
        info.addressDetails = [
            PostalAddress(label: "home", street: "1 Main St", city: "London", postalCode: "N1", country: "UK")
        ]
        return info
    }

    func store(_ edit: (inout FakeContactsStore.State) -> Void = { _ in }) -> FakeContactsStore {
        var state = FakeContactsStore.State()
        state.contacts = [ada]
        state.details = [ada]
        edit(&state)
        return FakeContactsStore(state)
    }

    func run(_ args: [String: Value], on store: FakeContactsStore) async throws -> ToolOutput {
        try await ContactsModule(store: store).call("delete_contact", Arguments(args))
    }

    func failure(_ args: [String: Value], on store: FakeContactsStore) async -> ToolError? {
        do {
            _ = try await run(args, on: store)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    @Test func badInputNeverReachesTheStore() async {
        let fake = store { $0.permission = .notDetermined }
        for args: [String: Value] in [[:], ["id": ""], ["id": "  "], ["id": 5], ["id": "p1", "confirm": "yes"]] {
            let error = await failure(args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func needsConfirmAndShowsTheContact() async throws {
        let fake = store()
        for confirm: Value? in [nil, false] {
            var args: [String: Value] = ["id": "p1"]
            if let confirm { args["confirm"] = confirm }
            let output = try await run(args, on: fake)
            let object = try #require(output.structured?.objectValue)
            #expect(object["confirm_required"]?.boolValue == true)
            let contact = try #require(object["contact"]?.objectValue)
            #expect(contact["name"]?.stringValue == "Ada Lovelace")
            #expect(contact["emails"]?.arrayValue?.count == 2)
            #expect(contact["phones"]?.arrayValue?.count == 1)
            #expect(output.text.hasPrefix("Nothing deleted."))
            #expect(output.text.contains("Ada Lovelace"))
            #expect(output.text.contains("ada@example.com"))
            #expect(output.text.contains("+44 20 7946 0958"))
        }
        #expect(fake.read(\.deleted) == nil)
        #expect(!fake.read(\.calls).contains("delete"))
    }

    @Test func deletesAndReturnsAFullCopy() async throws {
        let fake = store()
        let output = try await run(["id": " p1 ", "confirm": true], on: fake)
        #expect(fake.read(\.deleted) == "p1")
        let object = try #require(output.structured?.objectValue)
        #expect(object["deleted"]?.stringValue == "p1")
        let contact = try #require(object["contact"]?.objectValue)
        #expect(contact["given_name"]?.stringValue == "Ada")
        #expect(contact["family_name"]?.stringValue == "Lovelace")
        #expect(contact["job_title"]?.stringValue == "Mathematician")
        #expect(contact["birthday"]?.stringValue == "1815-12-10")
        #expect(contact["address_details"]?.arrayValue?.count == 1)
        #expect(output.text.contains("create_contact"))
    }

    @Test func recreateHasTheArgumentsOfCreateContact() async throws {
        let output = try await run(["id": "p1", "confirm": true], on: store())
        let recreate = try #require(output.structured?.objectValue?["recreate"]?.objectValue)
        #expect(
            Set(recreate.keys) == [
                "given_name", "family_name", "organization", "job_title", "emails", "phones", "addresses", "birthday",
            ])
        #expect(recreate["given_name"]?.stringValue == "Ada")
        #expect(recreate["organization"]?.stringValue == "Analytical Engines")
        let email = try #require(recreate["emails"]?.arrayValue?.first?.objectValue)
        #expect(email["label"]?.stringValue == "work")
        #expect(email["value"]?.stringValue == "ada@example.com")
        let address = try #require(recreate["addresses"]?.arrayValue?.first?.objectValue)
        #expect(address["postal_code"]?.stringValue == "N1")
        #expect(address["street"]?.stringValue == "1 Main St")
        // The copy never carries a note, and it is a valid input for create_contact.
        #expect(output.structured?.objectValue?["contact"]?.objectValue?["note"] == nil)
        // After the delete the contact is gone, so create_contact finds no duplicate.
        let emptied = store {
            $0.contacts = []
            $0.details = []
        }
        let created = try await ContactsModule(store: emptied).call("create_contact", Arguments(recreate))
        #expect(created.structured?.objectValue?["given_name"]?.stringValue == "Ada")
    }

    @Test func recreateLeavesOutEmptyFields() async throws {
        let bare = contactInfo("p9", "Solo")
        let output = try await run(["id": "p9", "confirm": true], on: store { $0.contacts = [bare] })
        let recreate = try #require(output.structured?.objectValue?["recreate"]?.objectValue)
        #expect(recreate.isEmpty)
    }

    @Test func unknownContactIsNotFound() async {
        let fake = store()
        let error = await failure(["id": "nope", "confirm": true], on: fake)
        #expect(error?.code == .notFound)
        #expect(fake.read(\.deleted) == nil)
    }

    @Test func aRefusedDeleteIsAnError() async {
        let refused = ToolError(
            .permissionDenied, "macOS refuses to delete this contact.", fix: "Delete it in Contacts.")
        let fake = store { $0.deleteError = refused }
        let error = await failure(["id": "p1", "confirm": true], on: fake)
        #expect(error?.code == .permissionDenied)
        #expect(error?.message == refused.message)
        #expect(fake.read(\.deleted) == nil)
    }

    #if os(macOS)
    @Test func aContactWithANoteGivesPermissionDeniedForADelete() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 134092)
        let mapped = CNContactsStore.saveFailure(error, verb: "delete")
        #expect(mapped.code == .permissionDenied)
        #expect(mapped.message.contains("refuses to delete this contact"))
        #expect(mapped.fix?.contains("Delete this contact in the Contacts app") == true)
        #expect(mapped.fix?.contains("Nothing was deleted") == true)
        let update = CNContactsStore.saveFailure(error)
        #expect(update.code == .permissionDenied)
        #expect(update.fix?.contains("Nothing was changed") == true)
        let other = CNContactsStore.saveFailure(NSError(domain: "x", code: 1), verb: "delete")
        #expect(other.code == .internalError)
        #expect(other.message.contains("could not delete the contact"))
    }
    #endif
}
