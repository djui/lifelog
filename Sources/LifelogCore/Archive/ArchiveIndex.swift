import Foundation

/// Current state of every item, folded from the ledger. Applying an event twice has no further effect.
public struct ArchiveIndex: Equatable {
    public var items: [ItemKey: ArchivedItem] = [:]
    /// Ledger read problems plus events that could not be applied.
    public var issues: [String] = []

    public init() {}

    public static func fold(_ events: [LedgerEvent]) -> ArchiveIndex {
        var index = ArchiveIndex()
        for event in events { index.apply(event) }
        return index
    }

    public mutating func apply(_ event: LedgerEvent) {
        let key = event.key
        switch event.type {
        case .added, .changed:
            // A changed event without a prior add is kept: the other Mac's add may not have synced yet.
            guard var item = event.item, item.key == key, item.payload.source == key.source else { return issue(event, "missing or mismatched item") }
            if let old = items[key] {
                item.state = old.state; item.stateSince = old.stateSince; item.reason = old.reason
                item.missingSince = old.missingSince; item.missingReason = old.missingReason
                item.firstSeen = [old.firstSeen, item.firstSeen].compactMap { $0 }.min()
            } else if item.firstSeen == nil {
                item.firstSeen = event.at
            }
            item.lastSeen = [items[key]?.lastSeen, item.lastSeen, event.at].compactMap { $0 }.max()
            items[key] = item
        case .stateChanged:
            guard let state = event.state else { return issue(event, "missing state") }
            guard var item = items[key] else { return issue(event, "unknown item") }
            if item.state != state { item.state = state; item.stateSince = event.at; item.reason = event.reason }
            item.missingSince = nil; item.missingReason = nil
            items[key] = item
        case .rekeyed:
            guard let newKey = event.newKey, newKey.source == key.source else { return issue(event, "missing or mismatched new key") }
            guard var item = items.removeValue(forKey: key) else {
                if items[newKey] == nil { issue(event, "unknown item") }
                return
            }
            if let existing = items[newKey] {
                let firstSeen = [existing.firstSeen, item.firstSeen].compactMap { $0 }.min()
                item = existing
                item.firstSeen = firstSeen
            } else {
                item.key = newKey
            }
            items[newKey] = item
        case .missingPending:
            guard items[key] != nil else { return issue(event, "unknown item") }
            if items[key]!.missingSince == nil { items[key]!.missingSince = event.at; items[key]!.missingReason = event.reason }
        case .missingCleared:
            guard items[key] != nil else { return issue(event, "unknown item") }
            items[key]!.missingSince = nil; items[key]!.missingReason = nil
        }
    }

    mutating func issue(_ event: LedgerEvent, _ problem: String) {
        issues.append("\(event.type.rawValue) \(event.key.source.rawValue)/\(event.key.id) at \(JSONLines.timestamp.string(from: event.at)): \(problem), ignored")
    }

    /// Folds the ledger, reusing a cache under `~/Library/Caches` while the ledger files are unchanged.
    /// The cache never lives in the synced archive folder.
    public static func load(_ ledger: Ledger, cacheRoot: URL? = defaultCacheRoot) throws -> ArchiveIndex {
        let stamps = ledger.stamps()
        let cacheURL = cacheRoot.map { cacheFile(for: ledger, in: $0) }
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cache = try? JSONLines.decoder.decode(Cache.self, from: data),
           cache.version == Cache.currentVersion, cache.archive == ledger.root.path, cache.files == stamps {
            var index = ArchiveIndex()
            index.items = Dictionary(uniqueKeysWithValues: cache.items.map { ($0.key, $0) })
            index.issues = cache.issues
            return index
        }
        let contents = try ledger.read()
        var index = fold(contents.events)
        index.issues = contents.issues + index.issues
        if let cacheRoot { index.save(ledger, cacheRoot: cacheRoot, stamps: stamps) }
        return index
    }

    /// Writes the cache for the ledger as it is on disk now. Call it after appending this index's events,
    /// so the next run skips the refold. A failed write only costs that refold.
    public func save(_ ledger: Ledger, cacheRoot: URL? = defaultCacheRoot) {
        guard let cacheRoot else { return }
        save(ledger, cacheRoot: cacheRoot, stamps: ledger.stamps())
    }

    func save(_ ledger: Ledger, cacheRoot: URL, stamps: [String: FileStamp]) {
        let cacheURL = Self.cacheFile(for: ledger, in: cacheRoot)
        let cache = Cache(archive: ledger.root.path, files: stamps, items: items.values.sorted { $0.key < $1.key }, issues: issues)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONLines.encoder.encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            ExportLog.info("could not write index cache: \(error.localizedDescription)")
        }
    }

    /// Per-archive cache folder under `cacheRoot`, also used for Claude Code read cursors.
    public static func cacheDirectory(for ledger: Ledger, in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(String(MarkdownWriter.digest(Data(ledger.root.path.utf8)).prefix(16)))
    }

    static func cacheFile(for ledger: Ledger, in cacheRoot: URL) -> URL { cacheDirectory(for: ledger, in: cacheRoot).appendingPathComponent("index.json") }

    public static var defaultCacheRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("com.djui.lifelog")
    }

    struct Cache: Codable {
        static let currentVersion = 2
        var version = currentVersion
        var archive: String
        var files: [String: FileStamp]
        var items: [ArchivedItem]
        var issues: [String]
    }
}
