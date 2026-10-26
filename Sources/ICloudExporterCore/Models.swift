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

public struct NoteRecord: Codable {
    public var id, title, account, folder: String
    public var created, modified: Date?
    public var bodyHTML: String
    /// Locked notes are archive stubs with an empty body; `export` skips them.
    public var isLocked: Bool?
    /// Two folders can share a name, so the archive keys folders by id.
    public var folderID: String?
    public init(id: String, title: String, account: String, folder: String, created: Date?, modified: Date?, bodyHTML: String,
                isLocked: Bool? = nil, folderID: String? = nil) {
        self.id = id; self.title = title; self.account = account; self.folder = folder
        self.created = created; self.modified = modified; self.bodyHTML = bodyHTML
        self.isLocked = isLocked; self.folderID = folderID
    }
}

public struct ReminderRecord: Codable {
    public var id, title, list: String
    public var notes: String?
    public var isCompleted: Bool
    public var completionDate: Date?
    /// Civil date or local date-time; date-only reminders must not become UTC midnight.
    public var due: String?
    public var priority: Int
    public var url: String?
    public var externalID: String?
    public var created, modified: Date?
    public init(id: String, title: String, list: String, notes: String?, isCompleted: Bool, completionDate: Date?, due: String?, priority: Int, url: String?,
                externalID: String? = nil, created: Date? = nil, modified: Date? = nil) {
        self.id = id; self.title = title; self.list = list; self.notes = notes
        self.isCompleted = isCompleted; self.completionDate = completionDate; self.due = due
        self.priority = priority; self.url = url
        self.externalID = externalID; self.created = created; self.modified = modified
    }
}

public struct CalendarRecord: Codable {
    public var id, title, calendar: String
    public var start, end: Date
    public var isAllDay: Bool
    public var timeZone, location, notes, url: String?
    /// All-day end dates are exclusive, matching EventKit.
    public var startDate, endDate: String?
    public var externalID: String?
    /// `none`, `confirmed`, `tentative` or `cancelled`.
    public var status: String?
    /// The current user's attendee status, such as `accepted` or `declined`; nil when not an attendee.
    public var participation: String?
    public var created, modified: Date?
    public init(id: String, title: String, calendar: String, start: Date, end: Date, isAllDay: Bool, timeZone: String?, location: String?, notes: String?, url: String?, startDate: String? = nil, endDate: String? = nil,
                externalID: String? = nil, status: String? = nil, participation: String? = nil, created: Date? = nil, modified: Date? = nil) {
        self.id = id; self.title = title; self.calendar = calendar; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.timeZone = timeZone; self.location = location
        self.notes = notes; self.url = url; self.startDate = startDate; self.endDate = endDate
        self.externalID = externalID; self.status = status; self.participation = participation
        self.created = created; self.modified = modified
    }
}

public struct WhatsAppMessageRecord: Codable {
    public var id, sender: String
    public var timestamp: Date
    public var fromMe: Bool
    public var text: String?
    public var placeholder: String?
    /// Not globally unique: the archive keys messages by chat JID + `fromMe` + stanza id.
    public var stanzaID: String?
    public var rawType: Int?
    /// "This message was deleted": the text is gone, the key stays.
    public var isRevoked: Bool?
    /// Group and chat events such as joins or setting changes.
    public var isSystem: Bool?
    public var sentDate: Date?
    public init(id: String, sender: String, timestamp: Date, fromMe: Bool, text: String?, placeholder: String?,
                stanzaID: String? = nil, rawType: Int? = nil, isRevoked: Bool? = nil, isSystem: Bool? = nil, sentDate: Date? = nil) {
        self.id = id; self.sender = sender; self.timestamp = timestamp
        self.fromMe = fromMe; self.text = text; self.placeholder = placeholder
        self.stanzaID = stanzaID; self.rawType = rawType; self.isRevoked = isRevoked
        self.isSystem = isSystem; self.sentDate = sentDate
    }
}

public struct WhatsAppChatRecord: Codable {
    public var id, title, kind, jid: String
    public var messages: [WhatsAppMessageRecord]
    public var isRemoved, isHidden: Bool?
    public init(id: String, title: String, kind: String, jid: String, messages: [WhatsAppMessageRecord],
                isRemoved: Bool? = nil, isHidden: Bool? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.jid = jid
        self.messages = messages; self.isRemoved = isRemoved; self.isHidden = isHidden
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
