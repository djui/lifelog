import Foundation
import CryptoKit

/// The folded index, cached in SQLite under `~/Library/Caches/com.djui.lifelog/<archive>/index.sqlite`, never in the
/// archive. It remembers how far each ledger file was read, so a load reads only the lines appended since, and a save
/// writes only the items that changed. Whenever that is not safe, it folds the whole ledger again:
///
/// - a ledger file shrank, vanished, or its bytes before the read position changed (a sync client replaced it);
/// - a new line is older than the latest one applied, such as another Mac's lines arriving late (the fold is ordered);
/// - an unknown folder or file appeared, so the read problems are reported exactly as a full read reports them.
///
/// The ledger stays the only source of truth: deleting the cache costs one full fold.
struct IndexStore {
    static let fileName = "index.sqlite"
    static let version = 1
    /// Bytes before a file's read position whose digest must still match, so a rewritten file is noticed.
    static let tailLength = 256

    let ledger: Ledger
    let url: URL

    init(ledger: Ledger, cacheRoot: URL) {
        self.ledger = ledger
        url = ArchiveIndex.cacheDirectory(for: ledger, in: cacheRoot).appendingPathComponent(Self.fileName)
    }

    struct FileState: Equatable { var offset: Int; var lines: Int; var tail: String }

    // MARK: Load

    func load() throws -> ArchiveIndex {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The JSON cache of earlier versions.
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("index.json"))
        let db: SQLite
        do { db = try open() } catch { return try refold(nil) }
        do {
            if let index = try catchUp(db) { return index }
        } catch {
            ExportLog.info("index cache unusable, folding the ledger again: \(error.localizedDescription)")
        }
        return try refold(db)
    }

    func open() throws -> SQLite {
        let db = try SQLite(url)
        try db.execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, offset INTEGER NOT NULL, lines INTEGER NOT NULL, tail TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS items (source TEXT NOT NULL, id TEXT NOT NULL, item BLOB NOT NULL, PRIMARY KEY (source, id));
            """)
        return db
    }

    /// The cached index brought up to date with the lines appended since, or nil when only a full fold will do.
    func catchUp(_ db: SQLite) throws -> ArchiveIndex? {
        let meta = try self.meta(db)
        guard meta["version"] == String(Self.version), meta["archive"] == ledger.root.path else { return nil }
        let stored = try files(db)
        guard let current = ledgerFiles() else { return nil }
        guard Set(stored.keys).isSubset(of: current.keys) else { return nil }

        var lines: [JSONLines.Line<LedgerEvent>] = []
        var issues: [String] = [], newer: [String] = [], newerSources = Set<String>()
        var positions: [String: FileState] = [:]
        for (path, size) in current.sorted(by: { $0.key < $1.key }) {
            let state = stored[path] ?? FileState(offset: 0, lines: 0, tail: "")
            guard size >= state.offset else { return nil }
            guard size > state.offset else { continue }
            let file = ledger.directory.appendingPathComponent(path)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let start = max(0, state.offset - Self.tailLength)
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.readToEnd() ?? Data()
            guard state.offset == 0 || Self.digest(data.prefix(state.offset - start)) == state.tail else { return nil }
            let fresh = data.dropFirst(state.offset - start)
            // A new file with no complete line may still be syncing; a full read decides whether that is fatal.
            if state.offset == 0, !fresh.contains(0x0A) { return nil }
            let (source, name) = (String(path.split(separator: "/")[0]), String(path.split(separator: "/")[1]))
            let before = (lines.count, newer.count)
            let read = JSONLines.parse(Data(fresh), file: "ledger/\(path)", host: JSONLines.parse(name)!.host, firstLine: state.lines,
                                       lines: &lines, issues: &issues, newer: &newer)
            if newer.count > before.1 { newerSources.insert(source) }
            if read.bytes > 0 {
                let end = state.offset - start + read.bytes
                positions[path] = FileState(offset: state.offset + read.bytes, lines: state.lines + read.count,
                                            tail: Self.digest(data[data.startIndex + max(0, end - Self.tailLength)..<data.startIndex + end]))
            }
            if lines[before.0...].contains(where: { $0.value.key.source.rawValue != source }) { return nil }
        }

        var index = ArchiveIndex()
        index.items = try items(db)
        index.issues = decode([String].self, meta["issues"]) ?? []
        index.newer = decode(NewerLines.self, meta["newer"]) ?? NewerLines()
        index.lastAt = meta["lastAt"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        index.changed = []
        guard !lines.isEmpty || !newer.isEmpty || !issues.isEmpty else { return index }
        ExportLog.info("reading \(lines.count) new ledger lines into the index")

        let events = JSONLines.merged(lines).map(\.value)
        if let lastAt = index.lastAt, let first = events.first, first.at < lastAt { return nil }
        for event in events { index.apply(event) }
        index.issues += issues
        index.newer.lines += newer
        index.newer.sources.formUnion(newerSources)
        try write(db, index, full: false, positions: positions)
        index.changed = []
        return index
    }

    /// Folds the whole ledger and replaces the cache with it.
    func refold(_ db: SQLite?) throws -> ArchiveIndex {
        ExportLog.info("folding the whole ledger into the index")
        let contents = try ledger.read()
        var index = ArchiveIndex.fold(contents.events)
        index.issues = contents.issues + index.issues
        index.newer = contents.newer
        do {
            let db = try db ?? open()
            try db.transaction { try db.execute("DELETE FROM items; DELETE FROM files; DELETE FROM meta;") }
            try write(db, index, full: true, positions: try allPositions())
        } catch {
            ExportLog.info("could not write index cache: \(error.localizedDescription)")
        }
        index.changed = []
        return index
    }

    // MARK: Save

    /// Writes the index after this Mac appended to the ledger. Only this Mac writes its own ledger files, and every line
    /// it appended was applied, so those files count as read to their end. Other Macs' files keep their read positions.
    func save(_ index: ArchiveIndex) throws {
        let db = try open()
        guard let current = ledgerFiles() else { return }
        let stored = try files(db)
        var positions: [String: FileState] = [:]
        for (path, size) in current where size != stored[path]?.offset && JSONLines.parse(String(path.split(separator: "/").last ?? ""))?.host == ledger.host {
            positions[path] = try position(path)
        }
        try write(db, index, full: index.changed == nil, positions: positions)
    }

    /// Writes items (all, or the changed ones), meta, and the given read positions.
    func write(_ db: SQLite, _ index: ArchiveIndex, full: Bool, positions: [String: FileState]) throws {
        try db.transaction {
            let upsert = try db.prepare("INSERT OR REPLACE INTO items (source, id, item) VALUES (?, ?, ?)")
            let delete = try db.prepare("DELETE FROM items WHERE source = ? AND id = ?")
            if full { try db.execute("DELETE FROM items") }
            let keys = full ? Array(index.items.keys) : Array(index.changed ?? [])
            for key in keys {
                if let item = index.items[key] {
                    try upsert.run([.text(key.source.rawValue), .text(key.id), .blob(try JSONLines.encoder.encode(item))])
                } else {
                    try delete.run([.text(key.source.rawValue), .text(key.id)])
                }
            }
            let file = try db.prepare("INSERT OR REPLACE INTO files (path, offset, lines, tail) VALUES (?, ?, ?, ?)")
            for (path, state) in positions { try file.run([.text(path), .int(Int64(state.offset)), .int(Int64(state.lines)), .text(state.tail)]) }
            let meta = try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
            var values = ["version": String(Self.version), "archive": ledger.root.path,
                          "issues": String(decoding: try JSONLines.encoder.encode(index.issues), as: UTF8.self),
                          "newer": String(decoding: try JSONLines.encoder.encode(index.newer), as: UTF8.self)]
            if let lastAt = index.lastAt { values["lastAt"] = String(lastAt.timeIntervalSince1970) }
            for (key, value) in values { try meta.run([.text(key), .text(value)]) }
        }
    }

    /// How far a file has complete lines: the end of its last line, how many lines that is, and the digest before it.
    func position(_ path: String) throws -> FileState {
        let data = try Data(contentsOf: ledger.directory.appendingPathComponent(path))
        guard let last = data.lastIndex(of: 0x0A) else { return FileState(offset: 0, lines: 0, tail: Self.digest(Data())) }
        let offset = last + 1
        let lines = data[..<offset].reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return FileState(offset: offset, lines: lines, tail: Self.digest(data[max(0, offset - Self.tailLength)..<offset]))
    }

    func allPositions() throws -> [String: FileState] {
        try Dictionary(uniqueKeysWithValues: (ledgerFiles() ?? [:]).keys.map { ($0, try position($0)) })
    }

    // MARK: Reading the cache and the ledger folder

    func meta(_ db: SQLite) throws -> [String: String] {
        var meta: [String: String] = [:]
        try db.query("SELECT key, value FROM meta") { meta[$0.text(0) ?? ""] = $0.text(1) }
        return meta
    }

    func files(_ db: SQLite) throws -> [String: FileState] {
        var files: [String: FileState] = [:]
        try db.query("SELECT path, offset, lines, tail FROM files") { row in
            files[row.text(0) ?? ""] = FileState(offset: Int(row.int(1)), lines: Int(row.int(2)), tail: row.text(3) ?? "")
        }
        return files
    }

    func items(_ db: SQLite) throws -> [ItemKey: ArchivedItem] {
        var items: [ItemKey: ArchivedItem] = [:]
        try db.query("SELECT item FROM items") { row in
            let item = try JSONLines.decoder.decode(ArchivedItem.self, from: row.blob(0) ?? Data())
            items[item.key] = item
        }
        return items
    }

    /// `<source>/<file>` → size of every ledger file, or nil when the folder holds anything a full read would report.
    func ledgerFiles() -> [String: Int]? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: ledger.directory.path) else { return [:] }
        guard let folders = try? manager.contentsOfDirectory(atPath: ledger.directory.path) else { return nil }
        var files: [String: Int] = [:]
        for folder in folders where !folder.hasPrefix(".") {
            guard ArchiveSource(rawValue: folder) != nil,
                  let names = try? manager.contentsOfDirectory(atPath: ledger.directory.appendingPathComponent(folder).path) else { return nil }
            for name in names where !name.hasPrefix(".") {
                guard JSONLines.parse(name) != nil,
                      let size = try? manager.attributesOfItem(atPath: ledger.directory.appendingPathComponent("\(folder)/\(name)").path)[.size] as? Int else { return nil }
                files["\(folder)/\(name)"] = size
            }
        }
        return files
    }

    /// The items and whether the cache has read every ledger file to its end, for `verify`. Nil when there is no usable cache.
    func snapshot() -> (upToDate: Bool, items: [ItemKey: ArchivedItem])? {
        guard FileManager.default.fileExists(atPath: url.path), let db = try? SQLite(url, readOnly: true),
              let meta = try? meta(db), meta["version"] == String(Self.version), meta["archive"] == ledger.root.path,
              let stored = try? files(db), let items = try? items(db), let current = ledgerFiles() else { return nil }
        let upToDate = Set(stored.keys) == Set(current.keys) && current.allSatisfy { path, _ in (try? position(path)) == stored[path] }
        return (upToDate, items)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func decode<Value: Decodable>(_ type: Value.Type, _ text: String?) -> Value? {
        text.flatMap { try? JSONLines.decoder.decode(type, from: Data($0.utf8)) }
    }
}
