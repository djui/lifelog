import Foundation

/// The readers `archive` uses on a real Mac. Each turns one source read into archive payloads and its scope.
public enum ArchiveReaders {
    /// Reminders and Calendar finish quickly, WhatsApp and Claude Code are local files, AI imports unpack zips,
    /// and Notes can take minutes, so it goes last.
    public static let order: [ArchiveSource] = [.reminders, .calendar, .whatsapp, .claudecode, .chatgpt, .claude, .notes]

    @MainActor
    public static func live(_ config: Config, cursorFile: URL?, digestCache: URL? = nil) -> [ArchiveReader] {
        let needsEventKit = config.sources.contains(.reminders) || config.sources.contains(.calendar)
        let eventKit = needsEventKit ? EventKitExporter() : nil
        let inbox = AIInbox(url: config.aiInbox, digestCache: digestCache)
        return order.filter(config.sources.contains).map { source -> ArchiveReader in
            switch source {
            case .notes: return NotesArchiveReader()
            case .reminders: return RemindersArchiveReader(eventKit: eventKit!)
            case .calendar: return CalendarArchiveReader(eventKit: eventKit!)
            case .whatsapp: return WhatsAppArchiveReader()
            case .chatgpt, .claude: return AIExportArchiveReader(source: source, inbox: inbox)
            case .claudecode: return ClaudeCodeArchiveReader(cursorFile: cursorFile)
            }
        }
    }
}

/// Every Notes read is full. Locked notes come as stubs, so a note that gets locked is not taken for deleted.
@MainActor
struct NotesArchiveReader: ArchiveReader {
    let source = ArchiveSource.notes
    let fixedMode: ReadMode? = nil

    func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead] {
        let result = try await NotesExporter.fetch(includeLocked: true)
        // The only warnings are omitted images and attachments; the notes themselves were all read.
        return [ArchiveRead(payloads: result.records.map(ArchivePayload.note), scope: .notes, warnings: result.warnings)]
    }
}

@MainActor
struct RemindersArchiveReader: ArchiveReader {
    let source = ArchiveSource.reminders
    let fixedMode: ReadMode? = nil
    let eventKit: EventKitExporter

    func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead] {
        // Backfill and full sweeps read every completed reminder.
        let completedSince = request.mode == .rescan ? request.from : nil
        let result = try await eventKit.reminders(completedSince: completedSince)
        return [ArchiveRead(payloads: result.records.map(ArchivePayload.reminder), scope: .reminders(completedSince: completedSince, liveFrom: request.liveFrom),
                            complete: result.warnings.isEmpty, warnings: result.warnings)]
    }
}

@MainActor
struct CalendarArchiveReader: ArchiveReader {
    let source = ArchiveSource.calendar
    let fixedMode: ReadMode? = nil
    let eventKit: EventKitExporter

    func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead] {
        let result = try await eventKit.events(from: request.from, to: request.until)
        return [ArchiveRead(payloads: result.records.map(ArchivePayload.event), scope: .calendar(from: request.from, to: request.until, liveFrom: request.liveFrom),
                            complete: result.warnings.isEmpty, warnings: result.warnings)]
    }
}

/// Every chat in the local WhatsApp Desktop database, with messages since the window start.
@MainActor
struct WhatsAppArchiveReader: ArchiveReader {
    let source = ArchiveSource.whatsapp
    let fixedMode: ReadMode? = nil
    var sourceDirectory: URL?

    func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead] {
        let result = try WhatsAppExporter.fetchArchive(since: request.from, now: request.now, sourceDirectory: sourceDirectory)
        // Missing data is a failed read, not an empty one: it must never look like every chat vanished.
        if result.warnings.contains(WhatsAppExporter.missingDataWarning) { throw ExportError.message(WhatsAppExporter.missingDataWarning) }
        return [Self.read(result, request: request)]
    }

    /// Only chats present in this read are in scope, so a chat that disappears as a whole is never tombstoned here.
    static func read(_ result: SourceResult<WhatsAppChatRecord>, request: ArchiveReadRequest) -> ArchiveRead {
        let payloads = result.records.flatMap { chat in
            chat.messages.map { ArchivePayload.message(WhatsAppArchiveMessage(chatJID: chat.jid, chatTitle: chat.title, chatKind: chat.kind, message: $0)) }
        }
        // The stanza-id warning only changes keys; the read itself is complete.
        return ArchiveRead(payloads: payloads, scope: Scope(from: request.from, containers: Set(result.records.map(\.jid)), liveFrom: request.liveFrom),
                           warnings: result.warnings)
    }
}

/// One scan of the AI export inbox per run, shared by the ChatGPT and Claude readers.
@MainActor
final class AIInbox {
    let url: URL
    /// Digests of the zips seen before, in the cache folder. The inbox is often `~/Downloads`.
    let digestCache: URL?
    private var scanned: SourceResult<AIExport>?

    init(url: URL, digestCache: URL? = nil) { self.url = url; self.digestCache = digestCache }

    func exports(skipping digests: Set<String>) -> SourceResult<AIExport> {
        if let scanned { return scanned }
        ExportLog.info("ai exports: scanning \(url.path)")
        let cache = ZipDigests(file: digestCache)
        let result = AIExportImporter.scan(inbox: url, skipDigests: digests, digest: cache.digest)
        cache.save()
        scanned = result
        return result
    }
}

/// SHA-256 per zip path, reused while the file's size and modification time stay the same, so a run does
/// not re-hash every zip in the inbox. Only zips seen in this scan are kept.
final class ZipDigests {
    struct Entry: Codable, Equatable { var stamp: FileStamp; var digest: String }
    let file: URL?
    private let known: [String: Entry]
    private(set) var seen: [String: Entry] = [:]
    private(set) var hashed = 0

    init(file: URL?) {
        self.file = file
        known = file.flatMap { try? JSONLines.decoder.decode([String: Entry].self, from: Data(contentsOf: $0)) } ?? [:]
    }

    func digest(_ url: URL) throws -> String {
        // URLs cache resource values; a stale size or time would reuse a stale digest.
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = FileStamp(size: values.fileSize ?? 0, modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let path = url.standardizedFileURL.path
        if let entry = known[path], entry.stamp == stamp {
            seen[path] = entry
            return entry.digest
        }
        let digest = try AIExportImporter.fileDigest(url)
        hashed += 1
        seen[path] = Entry(stamp: stamp, digest: digest)
        return digest
    }

    /// A failed write only costs re-hashing next run.
    func save() {
        guard let file, seen != known else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONLines.encoder.encode(seen).write(to: file, options: .atomic)
        } catch {
            ExportLog.info("could not write the AI inbox digest cache: \(error.localizedDescription)")
        }
    }
}

/// Each new export zip is one complete read of its service: a chat missing from a newer export goes the usual
/// way (pending, then deleted). The zips stay where they are.
@MainActor
struct AIExportArchiveReader: ArchiveReader {
    let source: ArchiveSource
    let fixedMode: ReadMode? = .import
    let inbox: AIInbox

    func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead] {
        let scan = inbox.exports(skipping: request.importedDigests)
        var reads = scan.records.filter { $0.source == source }.map(Self.read)
        // Inbox problems (unreadable folder, broken zip) belong to both services; log them without an import.
        if reads.isEmpty, !scan.warnings.isEmpty { reads = [ArchiveRead(payloads: [], scope: Scope(), complete: false, warnings: scan.warnings)] }
        return reads
    }

    static func read(_ export: AIExport) -> ArchiveRead {
        let payloads = export.chats.flatMap { chat in
            chat.messages.enumerated().map { position, message in
                // Both services give messages ids; the position keeps two identical id-less messages apart.
                var message = message
                if message.id == nil { message.id = "#\(position)" }
                return ArchivePayload.aiMessage(AIArchiveMessage(source: export.source, chatID: chat.id, chatTitle: chat.title, project: chat.project, message: message))
            }
        }
        ExportLog.info("\(export.source.rawValue): importing \(export.zip.lastPathComponent)")
        return ArchiveRead(payloads: payloads, scope: Scope(), complete: export.complete, warnings: export.warnings, digest: export.digest)
    }
}

/// New transcript lines since the last run. Claude Code removes old transcripts itself, so a vanished
/// session is not a deletion: nothing is ever in scope for absence here.
@MainActor
struct ClaudeCodeArchiveReader: ArchiveReader {
    let source = ArchiveSource.claudecode
    let fixedMode: ReadMode? = .incremental
    var root = ClaudeCodeReader.defaultRoot
    /// Read positions per transcript, kept in the cache folder. Without it every run reads everything again,
    /// which costs time but adds nothing twice.
    let cursorFile: URL?

    func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead] {
        guard FileManager.default.fileExists(atPath: root.path) else { throw ExportError.message("Claude Code transcripts were not found at \(root.path).") }
        var cursors = cursorFile.flatMap { try? JSONLines.decoder.decode([String: ClaudeCodeCursor].self, from: Data(contentsOf: $0)) } ?? [:]
        var titles: [String: String] = [:]
        for item in request.previous.values { if case .aiMessage(let value) = item.payload { titles[value.chatID] = value.chatTitle } }
        // A cursor whose session is not in the archive (a new archive, a reset ledger) would skip its earlier lines.
        cursors = cursors.filter { titles[(($0.key as NSString).lastPathComponent as NSString).deletingPathExtension] != nil }

        let result = ClaudeCodeReader.read(root: root, cursors: cursors)
        var payloads: [ArchivePayload] = []
        for session in result.records {
            let chat = session.chat
            // An incremental read sees only new lines, so its first prompt is not the session's.
            let title = (session.restarted ? nil : titles[chat.id]) ?? chat.title
            payloads += chat.messages.map { ArchivePayload.aiMessage(AIArchiveMessage(source: .claudecode, chatID: chat.id, chatTitle: title, project: chat.project, message: $0)) }
            cursors[session.path] = session.cursor
        }
        let commit: (() throws -> Void)? = cursorFile.map { file in {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONLines.encoder.encode(cursors).write(to: file, options: .atomic)
        } }
        return [ArchiveRead(payloads: payloads, scope: Scope(containers: []), warnings: result.warnings, commit: commit)]
    }
}
