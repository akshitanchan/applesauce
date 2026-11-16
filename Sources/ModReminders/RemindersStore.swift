import AppleSauceCore
import Foundation

struct ReminderListInfo: Encodable, Sendable, Equatable, Identified {
    let id: String
    let title: String
    let source: String?
    let writable: Bool
}

enum ReminderPriority: String, Encodable, Sendable, CaseIterable {
    case none, low, medium, high
}

/// A due date. `dateOnly` is true when the reminder has a day but no time.
struct ReminderDue: Sendable, Equatable {
    var date: Date
    var dateOnly: Bool
}

struct ReminderInfo: Encodable, Sendable, Equatable {
    let id: String
    let title: String
    let notes: String?
    let url: String?
    let due: Date?
    /// Only set when there is a due date.
    let dueDateOnly: Bool?
    let completed: Bool
    let completionDate: Date?
    let priority: ReminderPriority
    let list: String
    let listId: String
    /// True when the list does not allow changes.
    let readOnly: Bool
}

struct NewReminder: Sendable, Equatable {
    var title: String
    /// Nil means the default list for new reminders.
    var listId: String?
    var due: ReminderDue?
    var notes: String?
    var priority: ReminderPriority
    var url: String?
}

enum DueChange: Sendable, Equatable {
    case set(ReminderDue)
    case clear
}

/// Changes for `update_reminder`. A nil field stays as it is. For notes and url an empty string clears the value.
struct ReminderPatch: Sendable, Equatable {
    var title: String?
    var due: DueChange?
    var notes: String?
    var priority: ReminderPriority?
    var url: String?
}

/// The only way the reminders module reaches the reminder data.
/// The real store uses EventKit. Tests use a fake. No EventKit object leaves a store.
/// The id of a reminder is its EventKit `calendarItemIdentifier`.
protocol RemindersStore: Sendable {
    func accessState() -> PermissionState
    func requestAccess() async throws -> Bool
    func lists() async throws -> [ReminderListInfo]
    /// All reminders, complete and incomplete. An empty `listIds` means all lists. The module filters them.
    func reminders(listIds: [String]) async throws -> [ReminderInfo]
    func reminder(id: String) async throws -> ReminderInfo?
    func create(_ reminder: NewReminder) async throws -> ReminderInfo
    func update(id: String, _ patch: ReminderPatch) async throws -> ReminderInfo
    func setCompleted(id: String, _ completed: Bool) async throws -> ReminderInfo
    func delete(id: String) async throws
}
