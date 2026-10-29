import Foundation

/// What one read covered: "would this item have been read?". Only in-scope items can go missing.
/// Each item is placed by its scope date (`ArchivedItem.scopeDate`) and its container.
public struct Scope: Codable, Equatable {
    /// Items dated in `from..<until` were read; a nil bound is open.
    public var from, until: Date?
    /// Containers that were read, such as WhatsApp chat JIDs; nil means all of them.
    public var containers: Set<String>?
    /// Items dated before this have left the live window for good: when not seen, they become `archived`.
    public var liveFrom: Date?

    public init(from: Date? = nil, until: Date? = nil, containers: Set<String>? = nil, liveFrom: Date? = nil) {
        self.from = from; self.until = until; self.containers = containers; self.liveFrom = liveFrom
    }

    /// Messages since the rescan cutoff (or the backfill start) in the chats that were read.
    public static func whatsapp(since: Date?, chats: Set<String>?) -> Scope { Scope(from: since, containers: chats) }
    /// Occurrences starting inside the read window. Earlier ones are no longer re-read.
    public static func calendar(from: Date, to: Date, liveFrom: Date? = nil) -> Scope { Scope(from: from, until: to, liveFrom: liveFrom) }
    /// Open reminders always; completed ones since the cutoff, or all on a full sweep (`nil`).
    public static func reminders(completedSince: Date?, liveFrom: Date? = nil) -> Scope { Scope(from: completedSince, liveFrom: liveFrom) }
    /// Every Notes read is full.
    public static let notes = Scope()

    public func contains(_ item: ArchivedItem) -> Bool {
        if let containers, !containers.contains(StableKey.container(of: item.payload)) { return false }
        guard let date = item.scopeDate else { return true }
        return (from.map { date >= $0 } ?? true) && (until.map { date < $0 } ?? true)
    }

    public func hasLeftLiveWindow(_ item: ArchivedItem) -> Bool {
        guard let liveFrom, let date = item.scopeDate else { return false }
        return date < liveFrom
    }

    /// For the run log.
    public var summary: String {
        func time(_ date: Date?) -> String { date.map { JSONLines.timestamp.string(from: $0) } ?? "*" }
        var parts = ["\(time(from))..\(time(until))"]
        if let containers { parts.append("\(containers.count) containers") }
        if let liveFrom { parts.append("live from \(time(liveFrom))") }
        return parts.joined(separator: ", ")
    }
}

extension ArchivedItem {
    /// The date that decides scope. Nil means always in scope and never archived:
    /// notes (every read is full) and open reminders.
    public var scopeDate: Date? {
        switch payload {
        case .note: return nil
        case .reminder(let reminder): return reminder.isCompleted ? reminder.completionDate : nil
        case .event(let event): return event.start
        case .message(let value): return value.message.timestamp
        // An AI export is a complete read of the service; Claude Code reads only add.
        case .aiMessage: return nil
        }
    }
}
