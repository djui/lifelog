import Foundation

/// Current state of every item, folded from the ledger. Applying an event twice has no further effect.
public struct ArchiveIndex: Equatable {
    /// Every item by key. Changing items here rather than through `apply` makes the next cache save write all of them.
    public var items: [ItemKey: ArchivedItem] {
        get { stored }
        set { stored = newValue; changed = nil }
    }
    private var stored: [ItemKey: ArchivedItem] = [:]
    /// Keys `apply` changed since the index was loaded or saved, so a cache save writes only those. Nil: unknown, write all.
    var changed: Set<ItemKey>?
    /// The latest event applied. Lines older than this cannot be applied on top, so the cache refolds instead.
    var lastAt: Date?
    /// Ledger read problems plus events that could not be applied.
    public var issues: [String] = []
    /// Ledger lines a newer Lifelog wrote, left out of `items`. While any exist, the fold is incomplete:
    /// those sources are not read and no pages are written (see `Versioned`).
    public var newer = NewerLines()

    public init() {}

    public static func == (a: ArchiveIndex, b: ArchiveIndex) -> Bool { a.stored == b.stored && a.issues == b.issues && a.newer == b.newer }

    public static func fold(_ events: [LedgerEvent]) -> ArchiveIndex {
        var index = ArchiveIndex()
        for event in events { index.apply(event) }
        return index
    }

    public mutating func apply(_ event: LedgerEvent) {
        let key = event.key
        lastAt = max(lastAt ?? event.at, event.at)
        changed?.insert(key)
        if let newKey = event.newKey { changed?.insert(newKey) }
        switch event.type {
        case .added, .changed:
            // A changed event without a prior add is kept: the other Mac's add may not have synced yet.
            guard var item = event.item, item.key == key, item.payload.source == key.source else { return issue(event, "missing or mismatched item") }
            if let old = stored[key] {
                item.state = old.state; item.stateSince = old.stateSince; item.reason = old.reason
                item.missingSince = old.missingSince; item.missingReason = old.missingReason
                item.firstSeen = [old.firstSeen, item.firstSeen].compactMap { $0 }.min()
            } else if item.firstSeen == nil {
                item.firstSeen = event.at
            }
            item.lastSeen = [stored[key]?.lastSeen, item.lastSeen, event.at].compactMap { $0 }.max()
            stored[key] = item
        case .stateChanged:
            guard let state = event.state else { return issue(event, "missing state") }
            guard var item = stored[key] else { return issue(event, "unknown item") }
            if item.state != state { item.state = state; item.stateSince = event.at; item.reason = event.reason }
            item.missingSince = nil; item.missingReason = nil
            stored[key] = item
        case .rekeyed:
            guard let newKey = event.newKey, newKey.source == key.source else { return issue(event, "missing or mismatched new key") }
            guard var item = stored.removeValue(forKey: key) else {
                if stored[newKey] == nil { issue(event, "unknown item") }
                return
            }
            if let existing = stored[newKey] {
                let firstSeen = [existing.firstSeen, item.firstSeen].compactMap { $0 }.min()
                item = existing
                item.firstSeen = firstSeen
            } else {
                item.key = newKey
            }
            stored[newKey] = item
        case .missingPending:
            guard stored[key] != nil else { return issue(event, "unknown item") }
            if stored[key]!.missingSince == nil { stored[key]!.missingSince = event.at; stored[key]!.missingReason = event.reason }
        case .missingCleared:
            guard stored[key] != nil else { return issue(event, "unknown item") }
            stored[key]!.missingSince = nil; stored[key]!.missingReason = nil
        }
    }

    mutating func issue(_ event: LedgerEvent, _ problem: String) {
        issues.append("\(event.type.rawValue) \(event.key.source.rawValue)/\(event.key.id) at \(JSONLines.timestamp.string(from: event.at)): \(problem), ignored")
    }

    /// Folds the ledger, reusing the index cache under `~/Library/Caches` (see `IndexStore`). The cache never lives in the
    /// synced archive folder, and a cache that cannot be used costs only a full fold.
    public static func load(_ ledger: Ledger, cacheRoot: URL? = defaultCacheRoot) throws -> ArchiveIndex {
        guard let cacheRoot else {
            let contents = try ledger.read()
            var index = fold(contents.events)
            index.issues = contents.issues + index.issues
            index.newer = contents.newer
            return index
        }
        return try IndexStore(ledger: ledger, cacheRoot: cacheRoot).load()
    }

    /// Saves the items changed since the load to the cache. Call it after appending this index's events to the ledger,
    /// so the next run starts where this one ended. A failed save only costs a full fold next time.
    public mutating func save(_ ledger: Ledger, cacheRoot: URL? = defaultCacheRoot) {
        guard let cacheRoot else { return }
        do {
            try IndexStore(ledger: ledger, cacheRoot: cacheRoot).save(self)
            changed = []
        } catch {
            ExportLog.info("could not write index cache: \(error.localizedDescription)")
        }
    }

    /// Per-archive cache folder under `cacheRoot`, also used for Claude Code read cursors.
    public static func cacheDirectory(for ledger: Ledger, in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(String(MarkdownWriter.digest(Data(ledger.root.path.utf8)).prefix(16)))
    }

    public static var defaultCacheRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("com.djui.lifelog")
    }
}
