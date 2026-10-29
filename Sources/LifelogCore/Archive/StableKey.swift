import Foundation

/// Identity and content fingerprints for archived items. See the design doc on identity and schema note V1.
public enum StableKey {
    /// Base key per record. WhatsApp collisions are resolved in `items`, which sees the whole read.
    public static func id(of payload: ArchivePayload) -> String {
        switch payload {
        case .note(let note): return note.id
        case .reminder(let reminder): return reminder.externalID ?? "local:\(reminder.id)"
        case .event(let event):
            // Recurring occurrences share the external id, so the occurrence date is part of the key.
            let occurrence = event.isAllDay ? (event.startDate ?? JSONLines.timestamp.string(from: event.start)) : JSONLines.timestamp.string(from: event.start)
            return "\(event.externalID ?? "local:\(event.id)")@\(occurrence)"
        case .message(let value):
            // Stanza ids are unique per chat and sender only (V1); Z_PK changes when the database is rebuilt.
            let message = value.message
            return "\(value.chatJID)/\(message.fromMe ? 1 : 0)/\(message.stanzaID ?? "pk:\(message.id)")"
        case .aiMessage(let value):
            // Messages without an id fall back to their content; `items` disambiguates repeats.
            return "\(value.chatID)/\(value.message.id ?? "h:\(contentHash(of: payload).prefix(16))")"
        }
    }

    public static func nativeID(of payload: ArchivePayload) -> String {
        switch payload {
        case .note(let note): return note.id
        case .reminder(let reminder): return reminder.id
        case .event(let event): return event.id
        case .message(let value): return value.message.id
        case .aiMessage(let value): return value.message.id ?? id(of: payload)
        }
    }

    /// Chat, calendar, list or folder. Re-linking only pairs items within one container.
    public static func container(of payload: ArchivePayload) -> String {
        switch payload {
        case .note(let note): return note.folderID ?? "\(note.account)/\(note.folder)"
        case .reminder(let reminder): return reminder.list
        case .event(let event): return event.calendar
        case .message(let value): return value.chatJID
        case .aiMessage(let value): return value.chatID
        }
    }

    /// Hash of the normalized text. Times, states and containers are left out, so a rescheduled
    /// event or a re-keyed message still matches its earlier self when re-linking.
    public static func contentHash(of payload: ArchivePayload) -> String {
        let fields: [String?]
        switch payload {
        case .note(let note): fields = [note.title, note.bodyHTML]
        case .reminder(let reminder): fields = [reminder.title, reminder.notes, reminder.url, reminder.due, String(reminder.priority)]
        case .event(let event): fields = [event.title, event.location, event.notes, event.url, event.isAllDay ? "all-day" : "timed"]
        case .message(let value): fields = [value.message.sender, value.message.text, value.message.placeholder]
        case .aiMessage(let value): fields = [value.message.role, value.message.text] + value.message.attachments
        }
        return MarkdownWriter.digest(Data(fields.map { normalize($0 ?? "") }.joined(separator: "\u{1F}").utf8))
    }

    /// Non-text parts whose change is still a change: times, status, container, completion, lock.
    static func facets(of payload: ArchivePayload) -> [String] {
        func time(_ date: Date?) -> String { date.map { JSONLines.timestamp.string(from: $0) } ?? "" }
        switch payload {
        case .note(let note): return [note.account, container(of: payload), note.folder, String(note.isLocked ?? false)]
        case .reminder(let reminder): return [reminder.list, String(reminder.isCompleted), time(reminder.completionDate)]
        case .event(let event):
            return [event.calendar, time(event.start), time(event.end), event.startDate ?? "", event.endDate ?? "", event.timeZone ?? "", event.status ?? "", event.participation ?? ""]
        case .message(let value): return [String(value.message.isRevoked ?? false)]
        // Titles change as a chat goes on; that is not a change of each message.
        case .aiMessage: return []
        }
    }

    /// NFC, `\n` line endings, no trailing spaces per line, trimmed.
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Items for one read. Colliding WhatsApp keys gain the message date (V1); anything still
    /// colliding gains the native id, so every item of a read has its own key.
    public static func items(_ payloads: [ArchivePayload], at: Date, partition: (ArchivePayload) -> Partition) -> [ArchivedItem] {
        var ids = payloads.map(id(of:))
        func disambiguate(_ suffix: (ArchivePayload) -> String) {
            let counts = Dictionary(ids.map { ($0, 1) }, uniquingKeysWith: +)
            for index in ids.indices where counts[ids[index]]! > 1 { ids[index] += suffix(payloads[index]) }
        }
        disambiguate { payload in
            if case .message(let value) = payload { return "@\(JSONLines.timestamp.string(from: value.message.timestamp))" }
            return ""
        }
        disambiguate { "#\(nativeID(of: $0))" }
        return zip(payloads, ids).map { payload, id in
            ArchivedItem(key: ItemKey(source: payload.source, id: id), nativeID: nativeID(of: payload), partition: partition(payload),
                         stateSince: at, contentHash: contentHash(of: payload), payload: payload)
        }
    }
}

extension ArchivePayload {
    /// The state a sighting of this record implies.
    var observedState: LifecycleState {
        switch self {
        case .reminder(let reminder) where reminder.isCompleted: return .completed
        case .note(let note) where note.isLocked == true: return .locked
        case .message(let value) where value.message.isRevoked == true: return .revoked
        default: return .active
        }
    }
}
