import Foundation

/// One finished item of BackLog, the watch-later and read-later app: a video watched, an article read,
/// a podcast listened to, or anything skimmed or skipped.
public struct BackLogItem: Equatable {
    public var id: String
    public var url, title, kind, state: String
    public var added: Date
    public var consumed: Date
    public var author, site, sharedBy, note, details: String
    public var durationSeconds: Double
    public var takeaway: String?
    public var keyPoints: [String]

    public init(id: String, url: String, title: String, kind: String, state: String, added: Date, consumed: Date, author: String = "", site: String = "",
                sharedBy: String = "", note: String = "", details: String = "", durationSeconds: Double = 0, takeaway: String? = nil, keyPoints: [String] = []) {
        self.id = id; self.url = url; self.title = title; self.kind = kind; self.state = state; self.added = added; self.consumed = consumed
        self.author = author; self.site = site; self.sharedBy = sharedBy; self.note = note; self.details = details
        self.durationSeconds = durationSeconds; self.takeaway = takeaway; self.keyPoints = keyPoints
    }
}

/// Reads BackLog's library, the SwiftData (Core Data) store it syncs through iCloud, from a copy so the
/// running app is never disturbed. Only finished items are read, as in BackLog's own History export:
/// the queue is intentions, History is what happened.
public enum BackLogReader {
    public static let defaultStore = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BackLog/Library.store")

    static let finishedStates = ["done", "skimmed", "skipped"]

    public static func read(store: URL = defaultStore) throws -> [BackLogItem] {
        guard FileManager.default.fileExists(atPath: store.path) else {
            throw ExportError.message("The BackLog library was not found at \(store.path).")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lifelog-backlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = store.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: store.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: directory.appendingPathComponent(name + suffix))
        }
        let db = try SQLiteDB(url: directory.appendingPathComponent(name))
        defer { db.close() }
        guard try db.hasTable("ZITEM") else { throw ExportError.message("The BackLog library has no items table; BackLog may have changed its format.") }

        let states = finishedStates.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
            SELECT lower(hex(ZID)), ZURLSTRING, ZTITLE, ZKINDRAW, ZSTATERAW, ZADDEDAT, ZCONSUMEDAT, ZAUTHOR, ZSITENAME,
                   ZSHAREDBY, ZNOTE, ZDETAILS, ZDURATIONSECONDS, ZSUMMARYJSON
            FROM ZITEM WHERE ZSTATERAW IN (\(states)) AND ZID IS NOT NULL ORDER BY ZCONSUMEDAT, ZADDEDAT
            """
        var items: [BackLogItem] = []
        try db.forEach(sql) { row in
            guard let hex = row.text(0), hex.count == 32 else { return }
            let added = WhatsAppExporter.date(fromApple: row.double(5))
            // Finished items always have a finishing time; an old row without one belongs to the day it was added.
            let consumed = row.isNull(6) ? added : WhatsAppExporter.date(fromApple: row.double(6))
            let summary = row.text(13).flatMap { Summary.decode($0) }
            items.append(BackLogItem(id: uuid(hex), url: row.text(1) ?? "", title: row.text(2) ?? "", kind: row.text(3) ?? "link", state: row.text(4) ?? "done",
                                     added: added, consumed: consumed, author: row.text(7) ?? "", site: row.text(8) ?? "", sharedBy: row.text(9) ?? "",
                                     note: row.text(10) ?? "", details: row.text(11) ?? "", durationSeconds: row.double(12),
                                     takeaway: summary?.takeaway, keyPoints: summary?.keyPoints ?? []))
        }
        return items
    }

    /// `8-4-4-4-12`, lower-case, as BackLog's History export writes ids.
    static func uuid(_ hex: String) -> String {
        let c = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(c[$0]) }.joined(separator: "-")
    }

    /// The summary BackLog stores as JSON; only what the archive shows.
    struct Summary: Decodable {
        struct Point: Decodable { var text: String }
        var takeaway: String
        var keyPoints: [Point]

        static func decode(_ json: String) -> (takeaway: String?, keyPoints: [String])? {
            guard !json.isEmpty, let value = try? JSONDecoder().decode(Summary.self, from: Data(json.utf8)) else { return nil }
            return (value.takeaway.isEmpty ? nil : value.takeaway, value.keyPoints.map(\.text).filter { !$0.isEmpty })
        }
    }

    /// What finishing one is called, as BackLog shows it: Watched, Listened, Read.
    static func doneLabel(kind: String) -> String {
        switch kind {
        case "video", "reel": return "Watched"
        case "podcast", "music": return "Listened"
        case "article", "thread": return "Read"
        default: return "Done"
        }
    }

    static func label(_ item: BackLogItem) -> String {
        let state: String
        switch item.state {
        case "skimmed": state = "Skimmed"
        case "skipped": state = "Skipped"
        default: state = doneLabel(kind: item.kind)
        }
        return "\(state) · \(item.kind.prefix(1).uppercased() + item.kind.dropFirst())"
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The entry text: the link, who made it and who shared it, the summary, and the note.
    static func text(_ item: BackLogItem) -> String {
        let title = oneLine(item.title).isEmpty ? item.url : oneLine(item.title)
        var lines = [item.url.isEmpty ? title : "[\(title.replacingOccurrences(of: "]", with: "\\]"))](\(item.url))"]
        var facts = [item.author, item.site].map(oneLine).filter { !$0.isEmpty }
        facts = facts.enumerated().filter { $0.offset == 0 || $0.element.caseInsensitiveCompare(facts[0]) != .orderedSame }.map(\.element)
        if item.durationSeconds > 0 {
            let minutes = max(1, Int((item.durationSeconds / 60).rounded()))
            facts.append(item.kind == "article" || item.kind == "thread" || item.kind == "link" ? "\(minutes) min read" : "\(minutes) min")
        }
        if !item.sharedBy.isEmpty { facts.append("from \(oneLine(item.sharedBy))") }
        if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
        if let takeaway = item.takeaway { lines += ["", "> \(oneLine(takeaway))"] }
        if !item.keyPoints.isEmpty { lines += [""] + item.keyPoints.map { "- \(oneLine($0))" } }
        if item.takeaway == nil, item.keyPoints.isEmpty, !item.details.isEmpty { lines += ["", "> \(oneLine(String(item.details.prefix(500))))"] }
        let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { lines += ["", note] }
        return lines.joined(separator: "\n")
    }

    /// One entry per finished item, on a page per month it was finished in.
    static func entry(_ item: BackLogItem, timeZone: TimeZone = .current) -> ArchiveEntry {
        let month = String(Partition(item.consumed, timeZone: timeZone).date.prefix(7))
        return ArchiveEntry(source: .backlog, container: "history/\(month)", containerTitle: "History \(month)", id: item.id, timestamp: item.consumed,
                            label: label(item), text: text(item))
    }
}

/// Every read is full: an item that is no longer finished (put back in the queue, or deleted) goes the usual
/// way, pending and then deleted. A missing library fails the read, so it never looks like everything vanished.
@MainActor
struct BackLogArchiveReader: ArchiveReader {
    let source = ArchiveSource.backlog
    let fixedMode: ReadMode? = nil
    var store = BackLogReader.defaultStore

    func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead] {
        let items = try BackLogReader.read(store: store)
        ExportLog.info("backlog: \(items.count) finished items")
        return [ArchiveRead(payloads: items.map { .entry(BackLogReader.entry($0)) }, scope: Scope())]
    }
}
