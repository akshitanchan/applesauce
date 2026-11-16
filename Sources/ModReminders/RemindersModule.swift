import AppleSauceCore
import Foundation
import MCP

/// Reminders tools. The data comes from a `RemindersStore` (EventKit in the real binary).
public struct RemindersModule: Module {
    public static let moduleName = "reminders"
    public var name: String { Self.moduleName }
    public static let requiredPermissions: [Permission] = [.reminders]
    public var permissions: [Permission] { Self.requiredPermissions }

    let store: any RemindersStore
    let permissionTimeout: Double
    let backendTimeout: Double

    /// The real module, backed by EventKit.
    #if os(macOS)
    public init() {
        self.init(store: EventKitRemindersStore())
    }
    #endif

    init(store: any RemindersStore, permissionTimeout: Double = 120, backendTimeout: Double = 30) {
        self.store = store
        self.permissionTimeout = permissionTimeout
        self.backendTimeout = backendTimeout
    }

    // MARK: tools

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let dateNote = "ISO 8601, for example 2026-11-12 or 2026-11-12T09:30:00+01:00"
    private static let idNote = "Reminder id from list_reminders, search_reminders or get_reminder."
    private static let limitProperty = property("integer", "Most results to return. Default 50, maximum 500.")
    private static let priorityProperty: Value = [
        "type": "string", "enum": ["none", "low", "medium", "high"], "description": "Priority. Default none.",
    ]

    public var tools: [ToolSpec] { Self.toolSpecs }

    public static var toolSpecs: [ToolSpec] {
        [
            ToolSpec(
                name: "list_reminder_lists",
                description: "List all reminder lists with their id, source and whether they allow changes."),
            ToolSpec(
                name: "create_reminder_list",
                description:
                    "Create a reminder list. It fails when a list with the same name (any case) already exists. Without 'source' the list goes into the account of the default list.",
                properties: [
                    "name": Self.property("string", "Name of the new list."),
                    "source": Self.property(
                        "string", "Account name or id, for example iCloud. Default: the account of the default list."),
                ],
                required: ["name"], write: true),
            ToolSpec(
                name: "list_reminders",
                description:
                    "List reminders, sorted by due date, from one list or all. By default only incomplete ones. Dates are \(Self.dateNote). A date-only 'due_end' includes that whole day. Reminders without a due date are left out when a due range is given.",
                properties: [
                    "list": Self.property("string", "List name or id. Names ignore case. Default: all lists."),
                    "filter": [
                        "type": "string", "enum": ["incomplete", "completed", "all"],
                        "description": "Which reminders to show. Default incomplete.",
                    ],
                    "due_start": Self.property("string", "Only reminders due at or after this. \(Self.dateNote)"),
                    "due_end": Self.property("string", "Only reminders due before this. \(Self.dateNote)"),
                    "limit": Self.limitProperty,
                ]),
            ToolSpec(
                name: "search_reminders",
                description:
                    "Find reminders whose title or notes contain the query (ignores case), in all lists, complete and incomplete.",
                properties: [
                    "query": Self.property("string", "Text to look for."),
                    "limit": Self.limitProperty,
                ],
                required: ["query"]),
            ToolSpec(
                name: "get_reminder",
                description: "Get one reminder with all its details. Dates are returned in ISO 8601 with an offset.",
                properties: ["id": Self.property("string", Self.idNote)],
                required: ["id"]),
            ToolSpec(
                name: "create_reminder",
                description:
                    "Create a reminder. The due date is \(Self.dateNote). A date-only 'due' has a day but no time. Subtasks and tags are not supported, because EventKit has no public API for them.",
                properties: [
                    "title": Self.property("string", "Reminder title."),
                    "list": Self.property("string", "List name or id. Default: the default list."),
                    "due": Self.property("string", "Due date. \(Self.dateNote)"),
                    "notes": Self.property("string", "Notes."),
                    "priority": Self.priorityProperty,
                    "url": Self.property("string", "A URL, for example https://example.com."),
                ],
                required: ["title"], write: true),
            ToolSpec(
                name: "update_reminder",
                description:
                    "Change fields of a reminder. Send only the fields to change. An empty string clears 'due', 'notes' or 'url'. 'list' moves the reminder to another list. The due date is \(Self.dateNote).",
                properties: [
                    "id": Self.property("string", Self.idNote),
                    "title": Self.property("string", "New title."),
                    "due": Self.property("string", "New due date. Empty string clears it. \(Self.dateNote)"),
                    "notes": Self.property("string", "New notes. Empty string clears them."),
                    "priority": Self.priorityProperty,
                    "url": Self.property("string", "New URL. Empty string clears it."),
                    "list": Self.property("string", "Move the reminder to this list (name or id). Names ignore case."),
                ],
                required: ["id"], write: true, idempotent: true),
            ToolSpec(
                name: "complete_reminder",
                description: "Mark a reminder as completed, or as not completed with 'completed' set to false.",
                properties: [
                    "id": Self.property("string", Self.idNote),
                    "completed": Self.property("boolean", "true to complete (default), false to reopen."),
                ],
                required: ["id"], write: true, idempotent: true),
            ToolSpec(
                name: "delete_reminder",
                description:
                    "Delete a reminder. The result has a copy of the reminder, so create_reminder can put it back.",
                properties: ["id": Self.property("string", Self.idNote)],
                required: ["id"], destructive: true, idempotent: true),
        ]
    }

    // MARK: routing

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "list_reminder_lists": return try await listLists()
        case "create_reminder_list": return try await createReminderList(args)
        case "list_reminders": return try await listReminders(args)
        case "search_reminders": return try await searchReminders(args)
        case "get_reminder": return try await getReminder(args)
        case "create_reminder": return try await createReminder(args)
        case "update_reminder": return try await updateReminder(args)
        case "complete_reminder": return try await completeReminder(args)
        case "delete_reminder": return try await deleteReminder(args)
        default:
            throw ToolError(.unknownTool, "The reminders module has no tool named '\(tool)'.")
        }
    }

    // MARK: backend access

    /// Checks the permission (it may show the macOS prompt). Call it after the input checks.
    private func access() async throws {
        let store = store
        try await ensureAccess(
            .reminders, state: { store.accessState() }, request: { try await store.requestAccess() },
            timeout: permissionTimeout)
    }

    /// One backend call with the 30 second limit.
    private func backend<T: Sendable>(_ operation: @escaping @Sendable (any RemindersStore) async throws -> T)
        async throws -> T
    {
        let store = store
        return try await withTimeout(seconds: backendTimeout) { try await operation(store) }
    }

    private func list(named query: String?, writable: Bool = false) async throws -> ReminderListInfo? {
        guard let query else { return nil }
        let all = try await backend { try await $0.lists() }
        let found = try resolveByIdOrName(query, kind: "reminder list", in: all)
        if writable && !found.writable { throw Self.readOnlyList(found.title) }
        return found
    }

    private static func readOnlyList(_ name: String) -> ToolError {
        ToolError.invalidInput("Reminder list '\(name)' does not allow changes.")
    }

    private func existing(_ id: String) async throws -> ReminderInfo {
        guard let reminder = try await backend({ try await $0.reminder(id: id) }) else {
            throw ToolError(
                .notFound, "No reminder has the id '\(id)'.",
                fix: "Use an id from list_reminders or search_reminders. The reminder may have been deleted.")
        }
        return reminder
    }

    // MARK: output

    private struct ListList: Encodable { let lists: [ReminderListInfo] }
    private struct ReminderList: Encodable {
        let reminders: [ReminderInfo]
        let total: Int
        let truncated: Bool
    }
    private struct Deleted: Encodable {
        let deleted: String
        /// The reminder as it was, so create_reminder can make it again.
        let reminder: ReminderInfo
    }

    static func describe(_ reminder: ReminderInfo) -> String {
        var parts = ["\(reminder.completed ? "[x]" : "[ ]") \(reminder.title)"]
        if let due = reminder.due {
            parts.append("due \(ISODate.string(due))\(reminder.dueDateOnly == true ? " (date only)" : "")")
        }
        if reminder.priority != .none { parts.append("priority \(reminder.priority.rawValue)") }
        parts.append(reminder.list)
        parts.append("id: \(reminder.id)")
        return parts.joined(separator: " | ")
    }

    /// Incomplete first, then by due date (no date last), then by title.
    private func reminderList(_ reminders: [ReminderInfo], limit: Int) throws -> ToolOutput {
        let sorted = reminders.sorted {
            if $0.completed != $1.completed { return !$0.completed }
            switch ($0.due, $1.due) {
            case (let a?, let b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.title < $1.title
            }
        }
        let shown = Array(sorted.prefix(limit))
        let truncated = sorted.count > shown.count
        var lines = [
            truncated
                ? "Showing \(shown.count) of \(sorted.count) reminders. Raise 'limit' (maximum 500) or narrow the request."
                : "\(shown.count) reminders."
        ]
        lines += shown.map { "- " + Self.describe($0) }
        return try ToolOutput(
            text: lines.joined(separator: "\n"),
            payload: ReminderList(reminders: shown, total: sorted.count, truncated: truncated))
    }

    // MARK: read tools

    private func listLists() async throws -> ToolOutput {
        try await access()
        let lists = try await backend { try await $0.lists() }.sorted { $0.title < $1.title }
        var output = ["\(lists.count) reminder lists."]
        output += lists.map {
            "- \($0.title)\($0.source.map { " | \($0)" } ?? "") | \($0.writable ? "writable" : "read-only") | id: \($0.id)"
        }
        return try ToolOutput(text: output.joined(separator: "\n"), payload: ListList(lists: lists))
    }

    private func listReminders(_ args: Arguments) async throws -> ToolOutput {
        let listName = try args.string("list")
        let filter = try args.string("filter") ?? "incomplete"
        guard ["incomplete", "completed", "all"].contains(filter) else {
            throw ToolError.invalidInput("'filter' must be 'incomplete', 'completed' or 'all'.")
        }
        let dueStart = try args.date("due_start")
        let dueEnd = try args.date("due_end")
        let limit = try args.int("limit", default: 50, range: 1...500)
        var lower = dueStart?.date
        var upper = dueEnd.map(ISODate.exclusiveEnd)
        if let dueStart, let dueEnd {
            let range = try ISODate.range(start: dueStart, end: dueEnd)
            (lower, upper) = (range.start, range.end)
        }

        try await access()
        let ids = try await list(named: listName).map { [$0.id] } ?? []
        let all = try await backend { try await $0.reminders(listIds: ids) }
        let matches = all.filter { reminder in
            switch filter {
            case "incomplete" where reminder.completed: return false
            case "completed" where !reminder.completed: return false
            default: break
            }
            guard lower != nil || upper != nil else { return true }
            guard let due = reminder.due else { return false }
            return (lower.map { due >= $0 } ?? true) && (upper.map { due < $0 } ?? true)
        }
        return try reminderList(matches, limit: limit)
    }

    private func searchReminders(_ args: Arguments) async throws -> ToolOutput {
        let query = try args.requiredString("query")
        let limit = try args.int("limit", default: 50, range: 1...500)

        try await access()
        let all = try await backend { try await $0.reminders(listIds: []) }
        let hits = all.filter { reminder in
            [reminder.title, reminder.notes].contains {
                $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return try reminderList(hits, limit: limit)
    }

    private func getReminder(_ args: Arguments) async throws -> ToolOutput {
        let id = try args.requiredString("id")
        try await access()
        let reminder = try await existing(id)
        return try ToolOutput(text: Self.describe(reminder), payload: reminder)
    }

    // MARK: write tools

    private func priority(_ args: Arguments) throws -> ReminderPriority? {
        guard let text = try args.string("priority") else { return nil }
        guard let priority = ReminderPriority(rawValue: text.lowercased()) else {
            throw ToolError.invalidInput("'priority' must be 'none', 'low', 'medium' or 'high'.")
        }
        return priority
    }

    private func createReminder(_ args: Arguments) async throws -> ToolOutput {
        let title = try args.requiredString("title")
        let listName = try args.string("list")
        let due = try args.date("due").map { ReminderDue(date: $0.date, dateOnly: $0.dateOnly) }
        let notes = try args.string("notes")
        let priority = try priority(args) ?? .none
        let url = try args.url("url")

        try await access()
        let list = try await list(named: listName, writable: true)
        let draft = NewReminder(
            title: title, listId: list?.id, due: due, notes: notes, priority: priority,
            url: url?.isEmpty == true ? nil : url)
        let reminder = try await backend { try await $0.create(draft) }
        return try ToolOutput(text: "Created reminder: " + Self.describe(reminder), payload: reminder)
    }

    private func createReminderList(_ args: Arguments) async throws -> ToolOutput {
        let name = try args.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolError.invalidInput("'name' is required.") }
        let sourceName = try args.string("source")

        try await access()
        let existing = try await backend { try await $0.lists() }
        if let same = existing.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ToolError(
                .invalidInput, "A reminder list named '\(same.title)' already exists (id: \(same.id)).",
                fix: "Use the existing list, or choose another name.")
        }
        var sourceId: String?
        if let sourceName {
            let sources = try await backend { try await $0.sources() }
            sourceId = try resolveByIdOrName(sourceName, kind: "reminder account", in: sources).id
        }
        let account = sourceId
        let created = try await backend { try await $0.createList(name: name, sourceId: account) }
        return try ToolOutput(
            text:
                "Created reminder list: \(created.title)\(created.source.map { " | \($0)" } ?? "") | id: \(created.id)",
            payload: created)
    }

    private func updateReminder(_ args: Arguments) async throws -> ToolOutput {
        let id = try args.requiredString("id")
        let title = try args.string("title")
        if title?.isEmpty == true { throw ToolError.invalidInput("'title' must not be empty.") }
        var due: DueChange?
        if let text = try args.string("due") {
            if text.isEmpty {
                due = .clear
            } else if let parsed = try args.date("due") {
                due = .set(ReminderDue(date: parsed.date, dateOnly: parsed.dateOnly))
            }
        }
        var patch = ReminderPatch(
            title: title, due: due, notes: try args.string("notes"), priority: try priority(args),
            url: try args.url("url"))
        let listName = try args.string("list")
        guard patch != ReminderPatch() || listName != nil else {
            throw ToolError.invalidInput("Give at least one field to change.")
        }

        try await access()
        let current = try await existing(id)
        if current.readOnly { throw Self.readOnlyList(current.list) }
        patch.listId = try await list(named: listName, writable: true)?.id
        let changes = patch
        let reminder = try await backend { try await $0.update(id: id, changes) }
        return try ToolOutput(text: "Updated reminder: " + Self.describe(reminder), payload: reminder)
    }

    private func completeReminder(_ args: Arguments) async throws -> ToolOutput {
        let id = try args.requiredString("id")
        let completed = try args.bool("completed") ?? true

        try await access()
        let current = try await existing(id)
        if current.readOnly { throw Self.readOnlyList(current.list) }
        let reminder = try await backend { try await $0.setCompleted(id: id, completed) }
        let verb = completed ? "Completed" : "Reopened"
        return try ToolOutput(text: "\(verb) reminder: " + Self.describe(reminder), payload: reminder)
    }

    private func deleteReminder(_ args: Arguments) async throws -> ToolOutput {
        let id = try args.requiredString("id")

        try await access()
        let current = try await existing(id)
        if current.readOnly { throw Self.readOnlyList(current.list) }
        try await backend { try await $0.delete(id: id) }
        return try ToolOutput(
            text:
                "Deleted reminder: \(Self.describe(current)). To undo, call create_reminder with the fields in 'reminder'.",
            payload: Deleted(deleted: current.id, reminder: current))
    }
}
