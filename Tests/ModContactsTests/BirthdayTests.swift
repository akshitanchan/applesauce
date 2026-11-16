import Foundation
import Testing

@testable import ModContacts

@Suite struct BirthdayTests {
    @Test func formatsDateOnly() {
        #expect(CNContactsStore.birthdayText(DateComponents(year: 1815, month: 12, day: 10)) == "1815-12-10")
        #expect(CNContactsStore.birthdayText(DateComponents(month: 3, day: 7)) == "--03-07")
        #expect(
            CNContactsStore.birthdayText(DateComponents(year: NSDateComponentUndefined, month: 3, day: 7))
                == "--03-07")
        #expect(CNContactsStore.birthdayText(DateComponents(year: 2000)) == nil)
    }
}
