// The real reminders store. EventKit exists on macOS only.
#if os(macOS)
import AppleSauceCore
import EventKit
import Foundation

/// The real reminders store. It is the only code that touches EventKit.
/// EventKit objects stay inside this actor. Only plain structs leave it.
actor EventKitRemindersStore: RemindersStore {
    private let store = EKEventStore()

    nonisolated func accessState() -> PermissionState {
        SystemPermissionChecker().state(of: .reminders)
    }

    /// Uses the completion handler form. The async form sends the store out of this actor, which Swift 6.1 rejects.
    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToReminders { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func lists() async throws -> [ReminderListInfo] {
        store.calendars(for: .reminder).map(Self.info)
    }

    func sources() async throws -> [ReminderSourceInfo] {
        store.sources.filter { $0.sourceType != .subscribed && $0.sourceType != .birthdays }
            .map { ReminderSourceInfo(id: $0.sourceIdentifier, title: $0.title) }
    }

    func createList(name: String, sourceId: String?) async throws -> ReminderListInfo {
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = name
        if let sourceId {
            list.source = store.sources.first { $0.sourceIdentifier == sourceId }
        } else {
            list.source =
                store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first { $0.sourceType == .local }
        }
        guard list.source != nil else {
            throw ToolError(
                .notFound, "No account is available for a new reminder list.",
                fix: "Set a default list in the Reminders app, or pass 'source'.")
        }
        do {
            try store.saveCalendar(list, commit: true)
        } catch {
            throw ToolError(
                .internalError, "Reminders could not create the list: \(error.localizedDescription)",
                fix: "Check that the account allows new lists, or pass another 'source'.")
        }
        return Self.info(list)
    }

    func reminders(listIds: [String]) async throws -> [ReminderInfo] {
        var selected: [EKCalendar]?
        if !listIds.isEmpty {
            selected = listIds.compactMap { store.calendar(withIdentifier: $0) }
            if selected?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForReminders(in: selected)
        // The callback runs on another thread. It turns the reminders into plain structs there.
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.info))
            }
        }
    }

    func reminder(id: String) async throws -> ReminderInfo? {
        locate(id).map(Self.info)
    }

    func create(_ draft: NewReminder) async throws -> ReminderInfo {
        let reminder = EKReminder(eventStore: store)
        if let id = draft.listId {
            reminder.calendar = store.calendar(withIdentifier: id)
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        guard reminder.calendar != nil else {
            throw ToolError(
                .notFound, "There is no default list for new reminders.",
                fix: "Set a default list in the Reminders app, or pass 'list'.")
        }
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.priority = Self.number(draft.priority)
        reminder.url = draft.url.flatMap { URL(string: $0) }
        if let due = draft.due { reminder.dueDateComponents = Self.components(due) }
        try save(reminder)
        return Self.info(reminder)
    }

    func update(id: String, _ patch: ReminderPatch) async throws -> ReminderInfo {
        guard let reminder = locate(id) else { throw Self.missing(id) }
        if let title = patch.title { reminder.title = title }
        switch patch.due {
        case .set(let due)?: reminder.dueDateComponents = Self.components(due)
        case .clear?: reminder.dueDateComponents = nil
        case nil: break
        }
        if let notes = patch.notes { reminder.notes = notes.isEmpty ? nil : notes }
        if let priority = patch.priority { reminder.priority = Self.number(priority) }
        if let url = patch.url { reminder.url = url.isEmpty ? nil : URL(string: url) }
        if let listId = patch.listId {
            guard let list = store.calendar(withIdentifier: listId) else {
                throw ToolError(
                    .notFound, "No reminder list has the id '\(listId)'.", fix: "Use a list from list_reminder_lists.")
            }
            reminder.calendar = list
        }
        try save(reminder)
        return Self.info(reminder)
    }

    func setCompleted(id: String, _ completed: Bool) async throws -> ReminderInfo {
        guard let reminder = locate(id) else { throw Self.missing(id) }
        reminder.isCompleted = completed  // EventKit sets or clears the completion date
        try save(reminder)
        return Self.info(reminder)
    }

    func delete(id: String) async throws {
        guard let reminder = locate(id) else { throw Self.missing(id) }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw Self.saveError(error)
        }
    }

    // MARK: helpers

    private func locate(_ id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    private func save(_ reminder: EKReminder) throws {
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw Self.saveError(error)
        }
    }

    private static func saveError(_ error: Error) -> ToolError {
        ToolError(
            .internalError, "Reminders could not save the change: \(error.localizedDescription)",
            fix: "Check that the list allows changes and try again.")
    }

    private static func missing(_ id: String) -> ToolError {
        ToolError(
            .notFound, "No reminder has the id '\(id)'.",
            fix: "Use an id from list_reminders or search_reminders.")
    }

    /// EventKit priority: 0 none, 1 to 4 high, 5 medium, 6 to 9 low.
    private static func number(_ priority: ReminderPriority) -> Int {
        switch priority {
        case .none: 0
        case .high: 1
        case .medium: 5
        case .low: 9
        }
    }

    private static func priority(_ number: Int) -> ReminderPriority {
        switch number {
        case 1...4: .high
        case 5: .medium
        case 6...9: .low
        default: .none
        }
    }

    private static func components(_ due: ReminderDue) -> DateComponents {
        let units: Set<Calendar.Component> =
            due.dateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute, .second]
        return Calendar.current.dateComponents(units, from: due.date)
    }

    private static func info(_ list: EKCalendar) -> ReminderListInfo {
        ReminderListInfo(
            id: list.calendarIdentifier, title: list.title, source: list.source?.title,
            writable: list.allowsContentModifications)
    }

    private static func info(_ reminder: EKReminder) -> ReminderInfo {
        var due: Date?
        var dueDateOnly: Bool?
        if let parts = reminder.dueDateComponents {
            var calendar = parts.calendar ?? Calendar.current
            if let zone = parts.timeZone { calendar.timeZone = zone }
            due = calendar.date(from: parts)
            dueDateOnly = due == nil ? nil : parts.hour == nil
        }
        return ReminderInfo(
            id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
            notes: reminder.notes.flatMap { $0.isEmpty ? nil : $0 }, url: reminder.url?.absoluteString,
            due: due, dueDateOnly: dueDateOnly, completed: reminder.isCompleted,
            completionDate: reminder.completionDate, priority: priority(reminder.priority),
            list: reminder.calendar?.title ?? "", listId: reminder.calendar?.calendarIdentifier ?? "",
            readOnly: !(reminder.calendar?.allowsContentModifications ?? false))
    }
}
#endif
