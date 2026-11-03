import Foundation

/// Retires Claude Code messages archived twice. Before repeated transcript lines were dropped, a read that
/// saw a message twice archived it under `<chat>/<uuid>#<uuid>`, and a read without the repeat archived it
/// again under `<chat>/<uuid>`. Each such pair becomes one item through a `rekeyed` event from the `#` key
/// to its plain twin: the fold keeps the twin, with the earlier first sighting, and the viewer moves the `#`
/// item's history onto it. Nothing in the ledger is rewritten, and a `#` item without a plain twin stays.
public enum Dedupe {
    public static let reason = "duplicate of a repeated Claude Code line"

    public struct Pair: Equatable {
        public var duplicate: ItemKey
        public var twin: ItemKey
        /// The two copies' text differs; the twin's is kept in the index and the duplicate's stays in the ledger.
        public var textDiffers: Bool
    }

    /// Claude Code items whose key is their plain twin's key plus `#<native id>`, in key order.
    public static func pairs(in index: ArchiveIndex) -> [Pair] {
        index.items.values.compactMap { item -> Pair? in
            guard item.key.source == .claudecode, case .aiMessage = item.payload else { return nil }
            let suffix = "#\(item.nativeID)"
            guard item.key.id.hasSuffix(suffix) else { return nil }
            let twin = ItemKey(source: item.key.source, id: String(item.key.id.dropLast(suffix.count)))
            guard let plain = index.items[twin], plain.nativeID == item.nativeID,
                  StableKey.container(of: plain.payload) == StableKey.container(of: item.payload) else { return nil }
            return Pair(duplicate: item.key, twin: twin, textDiffers: plain.contentHash != item.contentHash)
        }
        .sorted { $0.duplicate < $1.duplicate }
    }

    public static func events(_ pairs: [Pair], at: Date, host: String) -> [LedgerEvent] {
        let run = "\(JSONLines.timestamp.string(from: at))-\(host)-dedupe"
        return pairs.map { LedgerEvent(type: .rekeyed, at: at, run: run, key: $0.duplicate, reason: reason, newKey: $0.twin) }
    }

    static func isDedupe(_ event: LedgerEvent) -> Bool { event.type == .rekeyed && event.reason == reason }

    /// Appends one `rekeyed` event per pair and returns the index with them applied, its cache saved.
    public static func retire(_ pairs: [Pair], ledger: Ledger, index: ArchiveIndex, now: Date, cacheRoot: URL? = ArchiveIndex.defaultCacheRoot) throws -> ArchiveIndex {
        guard !pairs.isEmpty else { return index }
        // The pages are rebuilt next, which needs the whole ledger.
        try index.newer.require()
        let events = try JSONLines.stored(events(pairs, at: now, host: ledger.host))
        try ledger.append(events)
        var index = index
        for event in events { index.apply(event) }
        index.save(ledger, cacheRoot: cacheRoot)
        return index
    }
}
