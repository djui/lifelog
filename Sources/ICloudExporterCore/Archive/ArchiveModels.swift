import Foundation

public typealias ArchiveSource = ExportSource

/// Lifecycle of an archived item. Items are never removed; they change state.
public enum LifecycleState: String, Codable, CaseIterable {
    case active, completed, archived, trashed, locked, deleted, expired, revoked, unknown

    /// Gone from the source or unaccounted for. Only a later sighting changes these.
    public var isTombstone: Bool { self == .deleted || self == .expired || self == .unknown }
}

public struct ItemKey: Codable, Hashable, Comparable {
    public var source: ArchiveSource
    /// Stable across re-syncs where the source allows it; see the design doc on identity.
    public var id: String
    public init(source: ArchiveSource, id: String) { self.source = source; self.id = id }
    public static func < (a: ItemKey, b: ItemKey) -> Bool { (a.source.rawValue, a.id) < (b.source.rawValue, b.id) }
}

/// Civil date the item belongs to, plus the UTC offset that produced it.
public struct Partition: Codable, Equatable {
    public var date: String
    public var utcOffset: Int
    public init(date: String, utcOffset: Int) { self.date = date; self.utcOffset = utcOffset }
}

public struct ItemFlags: Codable, Equatable {
    public var edited: Bool
    public var rescheduledFrom: String?
    /// Calendar status and participation before their latest change (decision 11).
    public var statusFrom, participationFrom: String?
    public init(edited: Bool = false, rescheduledFrom: String? = nil, statusFrom: String? = nil, participationFrom: String? = nil) {
        self.edited = edited; self.rescheduledFrom = rescheduledFrom; self.statusFrom = statusFrom; self.participationFrom = participationFrom
    }
}

public struct WhatsAppArchiveMessage: Codable {
    public var chatJID, chatTitle, chatKind: String
    public var message: WhatsAppMessageRecord
    public init(chatJID: String, chatTitle: String, chatKind: String, message: WhatsAppMessageRecord) {
        self.chatJID = chatJID; self.chatTitle = chatTitle; self.chatKind = chatKind; self.message = message
    }
}

public enum ArchivePayload {
    case note(NoteRecord), reminder(ReminderRecord), event(CalendarRecord), message(WhatsAppArchiveMessage)

    public var source: ArchiveSource {
        switch self {
        case .note: return .notes
        case .reminder: return .reminders
        case .event: return .calendar
        case .message: return .whatsapp
        }
    }
}

// The records belong to the readers and stay plain Codable, so equality compares the encoded form.
extension ArchivePayload: Equatable {
    public static func == (a: ArchivePayload, b: ArchivePayload) -> Bool {
        (try? JSONLines.encoder.encode(a)) == (try? JSONLines.encoder.encode(b))
    }
}

// Written as {"kind": "note", "note": {...}} so the ledger stays readable without this code.
extension ArchivePayload: Codable {
    enum CodingKeys: String, CodingKey { case kind, note, reminder, event, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "note": self = .note(try c.decode(NoteRecord.self, forKey: .note))
        case "reminder": self = .reminder(try c.decode(ReminderRecord.self, forKey: .reminder))
        case "event": self = .event(try c.decode(CalendarRecord.self, forKey: .event))
        case "message": self = .message(try c.decode(WhatsAppArchiveMessage.self, forKey: .message))
        case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown payload kind: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .note(let value): try c.encode("note", forKey: .kind); try c.encode(value, forKey: .note)
        case .reminder(let value): try c.encode("reminder", forKey: .kind); try c.encode(value, forKey: .reminder)
        case .event(let value): try c.encode("event", forKey: .kind); try c.encode(value, forKey: .event)
        case .message(let value): try c.encode("message", forKey: .kind); try c.encode(value, forKey: .message)
        }
    }
}

public struct ArchivedItem: Codable, Equatable {
    public var key: ItemKey
    public var nativeID: String
    public var partition: Partition
    public var state: LifecycleState
    /// When this state was first noticed, not when it happened at the source.
    public var stateSince: Date
    public var reason: String?
    public var firstSeen: Date?
    public var lastSeen: Date?
    /// Set while an in-scope item is missing but not yet confirmed gone.
    public var missingSince: Date?
    /// Why the item is pending, such as `mass-disappearance` when the circuit breaker held it.
    public var missingReason: String?
    public var flags: ItemFlags
    public var contentHash: String
    public var payload: ArchivePayload

    public init(key: ItemKey, nativeID: String, partition: Partition, state: LifecycleState = .active, stateSince: Date, reason: String? = nil,
                firstSeen: Date? = nil, lastSeen: Date? = nil, missingSince: Date? = nil, missingReason: String? = nil, flags: ItemFlags = ItemFlags(), contentHash: String, payload: ArchivePayload) {
        self.key = key; self.nativeID = nativeID; self.partition = partition; self.state = state; self.stateSince = stateSince
        self.reason = reason; self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.missingSince = missingSince
        self.missingReason = missingReason
        self.flags = flags; self.contentHash = contentHash; self.payload = payload
    }
}
