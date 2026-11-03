import Foundation

/// Everything the archive needs to know about one source, in one place: how it is read, when, how its
/// items behave, and where they show. Adding a source means one `ArchiveSource` case and its spec here.
public struct SourceSpec {
    public enum Lane { case frequent, hourly }
    public enum View { case notes, reminders, calendar, whatsapp, chats }

    /// The menu bar app's default schedule for the source.
    public var lane: Lane
    public var view: View
    /// Read from export zips left in the inbox. These are flagged when no new export arrived for a while.
    public var imported = false
    /// No read is ever complete, such as an export split into several zips, so items are only added, never tombstoned.
    public var addOnly = false
    /// Sources read from the same export zip. A zip imported for one of them is still new to the others.
    public var exportFamily: String?
    /// Items are generic `entry` payloads rather than chat messages.
    public var entries = false
    /// Builds the live reader.
    var reader: @MainActor (ReaderContext) -> ArchiveReader
}

/// What the live readers share: the configuration, one EventKit store and one inbox scan.
@MainActor
final class ReaderContext {
    let config: Config
    let cursorFile: URL?
    lazy var eventKit = EventKitExporter()
    let inbox: AIInbox

    init(config: Config, cursorFile: URL?, digestCache: URL?) {
        self.config = config; self.cursorFile = cursorFile
        inbox = AIInbox(url: config.aiInbox, digestCache: digestCache)
    }
}

extension ArchiveSource {
    /// Reminders and Calendar finish quickly, WhatsApp and Claude Code are local files, imports unpack zips,
    /// and Notes can take minutes, so it goes last.
    public static let archiveOrder: [ArchiveSource] = [.reminders, .calendar, .whatsapp, .claudecode, .chatgpt, .claude, .instagram, .messenger, .facebook, .notes]

    public var spec: SourceSpec {
        switch self {
        case .notes: return SourceSpec(lane: .hourly, view: .notes) { _ in NotesArchiveReader() }
        case .reminders: return SourceSpec(lane: .frequent, view: .reminders) { RemindersArchiveReader(eventKit: $0.eventKit) }
        case .calendar: return SourceSpec(lane: .frequent, view: .calendar) { CalendarArchiveReader(eventKit: $0.eventKit) }
        case .whatsapp: return SourceSpec(lane: .frequent, view: .whatsapp) { _ in WhatsAppArchiveReader() }
        case .claudecode: return SourceSpec(lane: .frequent, view: .chats) { ClaudeCodeArchiveReader(cursorFile: $0.cursorFile) }
        case .chatgpt, .claude: return SourceSpec(lane: .hourly, view: .chats, imported: true) { AIExportArchiveReader(source: self, inbox: $0.inbox) }
        case .instagram: return SourceSpec(lane: .hourly, view: .chats, imported: true, addOnly: true) { AIExportArchiveReader(source: self, inbox: $0.inbox) }
        case .messenger:
            return SourceSpec(lane: .hourly, view: .chats, imported: true, addOnly: true, exportFamily: "facebook") { AIExportArchiveReader(source: self, inbox: $0.inbox) }
        case .facebook:
            return SourceSpec(lane: .hourly, view: .chats, imported: true, addOnly: true, exportFamily: "facebook", entries: true) { AIExportArchiveReader(source: self, inbox: $0.inbox) }
        }
    }
}
