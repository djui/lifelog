import Foundation

/// Progress for long Apple reads. The CLI writes these to stderr; tests leave this unset.
public enum ExportLog {
    public static var handler: (@Sendable (String) -> Void)?
    public static func info(_ message: String) { handler?(message) }
}

public struct SourceResult<Record> {
    public var records: [Record]
    public var warnings: [String]
    public init(records: [Record], warnings: [String] = []) {
        self.records = records
        self.warnings = warnings
    }
}

public enum ExportError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let value): return value } }
}

public struct NoteRecord: Codable, Equatable {
    public var id, title, account, folder: String
    public var created, modified: Date?
    public var bodyHTML: String
    public init(id: String, title: String, account: String, folder: String, created: Date?, modified: Date?, bodyHTML: String) {
        self.id = id; self.title = title; self.account = account; self.folder = folder
        self.created = created; self.modified = modified; self.bodyHTML = bodyHTML
    }
}

public struct ReminderRecord: Codable, Equatable {
    public var id, title, list: String
    public var notes: String?
    public var isCompleted: Bool
    public var completionDate: Date?
    /// Civil date or local date-time; date-only reminders must not become UTC midnight.
    public var due: String?
    public var priority: Int
    public var url: String?
    public init(id: String, title: String, list: String, notes: String?, isCompleted: Bool, completionDate: Date?, due: String?, priority: Int, url: String?) {
        self.id = id; self.title = title; self.list = list; self.notes = notes
        self.isCompleted = isCompleted; self.completionDate = completionDate; self.due = due
        self.priority = priority; self.url = url
    }
}

public struct CalendarRecord: Codable, Equatable {
    public var id, title, calendar: String
    public var start, end: Date
    public var isAllDay: Bool
    public var timeZone, location, notes, url: String?
    /// All-day end dates are exclusive, matching EventKit.
    public var startDate, endDate: String?
    public init(id: String, title: String, calendar: String, start: Date, end: Date, isAllDay: Bool, timeZone: String?, location: String?, notes: String?, url: String?, startDate: String? = nil, endDate: String? = nil) {
        self.id = id; self.title = title; self.calendar = calendar; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.timeZone = timeZone; self.location = location
        self.notes = notes; self.url = url; self.startDate = startDate; self.endDate = endDate
    }
}

public struct WhatsAppMessageRecord: Codable, Equatable {
    public var id, sender: String
    public var timestamp: Date
    public var fromMe: Bool
    public var text: String?
    public var placeholder: String?
    public init(id: String, sender: String, timestamp: Date, fromMe: Bool, text: String?, placeholder: String?) {
        self.id = id; self.sender = sender; self.timestamp = timestamp
        self.fromMe = fromMe; self.text = text; self.placeholder = placeholder
    }
}

public struct WhatsAppChatRecord: Codable, Equatable {
    public var id, title, kind, jid: String
    public var messages: [WhatsAppMessageRecord]
    public init(id: String, title: String, kind: String, jid: String, messages: [WhatsAppMessageRecord]) {
        self.id = id; self.title = title; self.kind = kind; self.jid = jid
        self.messages = messages
    }
}

public enum ExportSource: String, Codable, CaseIterable {
    case notes, reminders, calendar, whatsapp

    public var directoryName: String {
        switch self {
        case .notes: return "Notes"
        case .reminders: return "Reminders"
        case .calendar: return "Calendar"
        case .whatsapp: return "WhatsApp"
        }
    }

    public var displayName: String { directoryName }
}

public struct ExportSnapshot {
    public var notes: [NoteRecord] = []
    public var reminders: [ReminderRecord] = []
    public var events: [CalendarRecord] = []
    public var chats: [WhatsAppChatRecord] = []
    public var warnings: [ExportSource: [String]] = [:]
    public init() {}
}
