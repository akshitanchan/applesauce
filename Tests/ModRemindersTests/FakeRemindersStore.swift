import AppleSauceCore
import Foundation

@testable import ModReminders

/// A reminders store in memory. It records every call. It never touches EventKit.
final class FakeRemindersStore: RemindersStore, @unchecked Sendable {
    struct State {
        var permission: PermissionState = .granted
        /// What `requestAccess` returns. On true the permission becomes granted.
        var requestResult = true
        /// Seconds that `requestAccess` and `reminder` wait first (to test time limits).
        var requestDelay: Double = 0
        var reminderDelay: Double = 0
        var lists: [ReminderListInfo] = []
        var sources: [ReminderSourceInfo] = []
        var createdList: (name: String, sourceId: String?)?
        var reminders: [ReminderInfo] = []
        var calls: [String] = []
        var listQuery: [String]?
        var created: NewReminder?
        var updated: (id: String, patch: ReminderPatch)?
        var completed: (id: String, value: Bool)?
        var deleted: String?
    }

    private let lock = NSLock()
    private var state: State

    init(_ state: State = State()) {
        self.state = state
    }

    func read<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func write(_ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&state)
    }

    func accessState() -> PermissionState { read(\.permission) }

    func requestAccess() async throws -> Bool {
        write { $0.calls.append("request") }
        let delay = read(\.requestDelay)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        let result = read(\.requestResult)
        if result { write { $0.permission = .granted } }
        return result
    }

    func lists() async throws -> [ReminderListInfo] {
        write { $0.calls.append("lists") }
        return read(\.lists)
    }

    func sources() async throws -> [ReminderSourceInfo] {
        write { $0.calls.append("sources") }
        return read(\.sources)
    }

    func createList(name: String, sourceId: String?) async throws -> ReminderListInfo {
        write {
            $0.calls.append("createList")
            $0.createdList = (name, sourceId)
        }
        return ReminderListInfo(id: "NEWLIST", title: name, source: "iCloud", writable: true)
    }

    func reminders(listIds: [String]) async throws -> [ReminderInfo] {
        write {
            $0.calls.append("reminders")
            $0.listQuery = listIds
        }
        return read(\.reminders).filter { listIds.isEmpty || listIds.contains($0.listId) }
    }

    func reminder(id: String) async throws -> ReminderInfo? {
        write { $0.calls.append("reminder") }
        let delay = read(\.reminderDelay)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return read(\.reminders).first { $0.id == id }
    }

    func create(_ reminder: NewReminder) async throws -> ReminderInfo {
        write {
            $0.calls.append("create")
            $0.created = reminder
        }
        let list = read(\.lists).first { $0.id == reminder.listId } ?? read(\.lists)[0]
        return makeReminder(
            "NEW", reminder.title, due: reminder.due, notes: reminder.notes, priority: reminder.priority, list: list)
    }

    func update(id: String, _ patch: ReminderPatch) async throws -> ReminderInfo {
        write {
            $0.calls.append("update")
            $0.updated = (id, patch)
        }
        return read(\.reminders).first { $0.id == id }!
    }

    func setCompleted(id: String, _ completed: Bool) async throws -> ReminderInfo {
        write {
            $0.calls.append("complete")
            $0.completed = (id, completed)
        }
        return read(\.reminders).first { $0.id == id }!
    }

    func delete(id: String) async throws {
        write {
            $0.calls.append("delete")
            $0.deleted = id
        }
    }
}

// MARK: sample data

func date(_ text: String) -> Date { ISODate.parse(text)!.date }

func listInfo(_ id: String, _ title: String, writable: Bool = true) -> ReminderListInfo {
    ReminderListInfo(id: id, title: title, source: "iCloud", writable: writable)
}

func makeReminder(
    _ id: String, _ title: String, due: ReminderDue? = nil, notes: String? = nil, completed: Bool = false,
    priority: ReminderPriority = .none, list: ReminderListInfo = listInfo("l1", "Inbox")
) -> ReminderInfo {
    ReminderInfo(
        id: id, title: title, notes: notes, url: nil, due: due?.date, dueDateOnly: due?.dateOnly,
        completed: completed, completionDate: nil, priority: priority, list: list.title, listId: list.id,
        readOnly: !list.writable)
}

func due(_ text: String) -> ReminderDue {
    let parsed = ISODate.parse(text)!
    return ReminderDue(date: parsed.date, dateOnly: parsed.dateOnly)
}
