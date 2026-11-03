import Foundation

/// `_archive.sqlite`: the archive as one read-only SQLite database for SQL and AI tools (`sqlite3`, Datasette, DuckDB).
/// Like the pages, it is a view of the ledger and can be deleted; `rebuild` writes it again.
///
/// It is built whole in a local temporary folder and then moved into place with a rename, so a sync client never sees
/// it half written. It is never opened for writing inside the archive folder. It is large (hundreds of megabytes for a big
/// archive) and every rewrite syncs in full, so an `archive` run rewrites it at most once a day; `rebuild` always does.
/// The full records stay in the ledger; this holds what a query needs.
public enum ArchiveDatabase {
    public static let fileName = "_archive.sqlite"
    static let interval: TimeInterval = 86_400

    /// Missing, or older than a day.
    static func due(_ root: URL, now: Date = Date()) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(fileName).path))?[.modificationDate] as? Date else { return true }
        return now.timeIntervalSince(modified) >= interval
    }

    static func write(_ context: ViewContext, to root: URL) throws {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("lifelog-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }
        let built = scratch.appendingPathComponent(fileName)
        try build(context, at: built)

        // Copied next to the target first, so the final step is a rename on one volume.
        let staged = root.appendingPathComponent(".\(fileName).\(UUID().uuidString.prefix(8)).tmp")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: built, to: staged)
        guard rename(staged.path, root.appendingPathComponent(fileName).path) == 0 else {
            throw ExportError.message("Cannot move \(fileName) into place: \(String(cString: strerror(errno)))")
        }
    }

    static func build(_ context: ViewContext, at url: URL) throws {
        let db = try SQLite(url)
        try db.execute("""
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE items (
                source TEXT NOT NULL,          -- such as whatsapp, calendar, facebook
                id TEXT NOT NULL,              -- the item's key within its source
                day TEXT NOT NULL,             -- the civil date it belongs to, YYYY-MM-DD
                time TEXT,                     -- HH:MM on that day, where the item has one
                state TEXT NOT NULL,           -- active, completed, archived, locked, deleted, expired, revoked, unknown
                title TEXT,                    -- note, reminder or event title
                who TEXT,                      -- sender of a message, role in an AI chat, kind of a Facebook entry
                "group" TEXT,                  -- chat, calendar, list, folder or AI chat
                text TEXT NOT NULL,
                badges TEXT NOT NULL,          -- JSON list, such as ["edited"]
                page TEXT NOT NULL,            -- the Markdown page that shows it, relative to the archive folder
                first_seen TEXT, last_seen TEXT, state_since TEXT, reason TEXT,
                PRIMARY KEY (source, id)
            );
            CREATE INDEX items_day ON items (day);
            CREATE VIRTUAL TABLE items_fts USING fts5 (title, who, "group", text, content = 'items');
            CREATE TABLE runs (
                run TEXT NOT NULL, source TEXT NOT NULL, start TEXT NOT NULL, "end" TEXT NOT NULL, complete INTEGER NOT NULL,
                mode TEXT, scope TEXT NOT NULL, counts TEXT NOT NULL, warnings TEXT NOT NULL
            );
            """)
        func json(_ value: some Encodable) throws -> String { String(decoding: try JSONLines.encoder.encode(value), as: UTF8.self) }
        func text(_ value: String?) -> SQLite.Value { value.map { .text($0) } ?? .null }
        try db.transaction {
            let insert = try db.prepare("""
                INSERT INTO items (source, id, day, time, state, title, who, "group", text, badges, page, first_seen, last_seen, state_since, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for item in context.index.items.values.sorted(by: { $0.key < $1.key }) {
                let view = ViewerData.item(item, context, history: [])
                let home = ArchivePages.home(item, context)
                try insert.run([.text(item.key.source.rawValue), .text(item.key.id), .text(view.day), text(view.time), .text(view.state),
                                text(view.title), text(view.who), text(view.group), .text(view.text), .text(try json(view.badges)),
                                .text(home.path + (home.anchor.map { "#\($0)" } ?? "")),
                                text(item.firstSeen.map(context.iso)), text(context.lastSeen(item).map(context.iso)), .text(context.iso(item.stateSince)),
                                text(item.reason)])
            }
            try db.execute("INSERT INTO items_fts (items_fts) VALUES ('rebuild')")
            let run = try db.prepare("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
            for record in context.records {
                try run.run([.text(record.run), .text(record.source.rawValue), .text(context.iso(record.start)), .text(context.iso(record.end)),
                             .int(record.complete ? 1 : 0), text(record.mode), .text(record.scope), .text(try json(record.counts)), .text(try json(record.warnings))])
            }
            let meta = try db.prepare("INSERT INTO meta VALUES (?, ?)")
            for (key, value) in [("generated", context.iso(context.now)), ("ledger_format", String(LedgerEvent.currentVersion)), ("demo", String(context.demo))] {
                try meta.run([.text(key), .text(value)])
            }
        }
    }
}
