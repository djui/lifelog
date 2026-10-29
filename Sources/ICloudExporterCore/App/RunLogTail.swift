import Foundation

/// The run log for the menu bar app, read as it grows. Each check reads only lines appended since the last one, and
/// only the records the app uses are kept, so the cost stays flat however long the archive runs: every record of
/// the last `window`, the last `perSource` of each source (failure streaks), each source's newest import (export
/// reminders) and the first record (when the archive started).
public final class RunLogTail {
    public static let window: TimeInterval = 60 * 86_400
    public static let perSource = 10

    let directory: URL
    private var offsets: [String: UInt64] = [:]
    private var kept: [RunRecord] = []
    private var first: RunRecord?

    public init(_ runLog: RunLog) { directory = runLog.directory }

    /// The kept records, oldest first.
    public private(set) var records: [RunRecord] = []

    /// Reads what was appended since the last call. A file that shrank or disappeared means the log was replaced
    /// (restored, or rewritten by a sync client), so everything is read again.
    public func update(now: Date = Date()) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { JSONLines.parse($0) != nil }.sorted()
        var fresh: [RunRecord] = []
        var reset = !Set(offsets.keys).subtracting(names).isEmpty
        for name in names where !reset {
            let url = directory.appendingPathComponent(name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value else { continue }
            let offset = offsets[name] ?? 0
            if size < offset { reset = true; continue }
            guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 0x0A) else { continue }
            // A torn last line is left for the next call.
            offsets[name] = offset + UInt64(end - data.startIndex + 1)
            for row in data[..<end].split(separator: 0x0A) where !row.isEmpty {
                if let record = try? JSONLines.decoder.decode(RunRecord.self, from: Data(row)) { fresh.append(record) }
            }
        }
        if reset {
            offsets = [:]; kept = []; first = nil; records = []
            return update(now: now)
        }
        guard !fresh.isEmpty else { return }
        first = (fresh + [first].compactMap { $0 }).min { $0.start < $1.start }
        kept = Self.trim(kept + fresh, now: now)
        records = (kept + (first.map { first in kept.contains(first) ? [] : [first] } ?? []))
            .sorted { ($0.end, $0.source.rawValue, $0.run) < ($1.end, $1.source.rawValue, $1.run) }
    }

    /// The records the app needs, from any number of them.
    static func trim(_ records: [RunRecord], now: Date) -> [RunRecord] {
        var keep = Set<Int>()
        for (index, record) in records.enumerated() where now.timeIntervalSince(record.end) <= window { keep.insert(index) }
        for indices in Dictionary(grouping: records.indices, by: { records[$0].source }).values {
            let newest = indices.sorted { records[$0].end > records[$1].end }
            keep.formUnion(newest.prefix(perSource))
            if let imported = newest.first(where: { records[$0].digest != nil }) { keep.insert(imported) }
        }
        return keep.sorted().map { records[$0] }
    }
}
