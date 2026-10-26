import Foundation

public struct VerifyReport: Equatable {
    /// Anything that makes the archive untrustworthy; `verify` exits non-zero on these.
    public var problems: [String] = []
    /// Worth knowing, but expected now and then, such as a stale cache.
    public var notes: [String] = []
    public var events = 0
    public var runs = 0
    public var items = 0
}

/// Read-only consistency check of an archive folder: ledger and run log lines, the fold, and the index cache.
public enum Verifier {
    public static func verify(root: URL, cacheRoot: URL? = ArchiveIndex.defaultCacheRoot) throws -> VerifyReport {
        var report = VerifyReport()
        // Appends never happen here, so the host name is only a placeholder.
        let ledger = Ledger(root: root, host: "verify")
        guard FileManager.default.fileExists(atPath: ledger.directory.path) else {
            report.problems.append("No ledger at \(ledger.directory.path).")
            return report
        }

        var lines: [JSONLines.Line<LedgerEvent>] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: ledger.directory.path).sorted() where !name.hasPrefix(".") {
            guard let source = ArchiveSource(rawValue: name) else { report.problems.append("ledger/\(name): unknown source folder"); continue }
            let result = try JSONLines.read(LedgerEvent.self, in: ledger.directory.appendingPathComponent(name), label: "ledger/\(name)")
            report.problems += result.issues
            for line in result.lines {
                if line.value.key.source != source { report.problems.append("\(line.location): \(line.value.key.source.rawValue) event in the \(name) folder") }
                if line.value.v != 1 { report.problems.append("\(line.location): unknown event version \(line.value.v)") }
                if line.value.key.id.isEmpty { report.problems.append("\(line.location): empty key") }
            }
            lines += result.lines.filter { $0.value.key.source == source }
        }
        lines = JSONLines.merged(lines)
        report.events = lines.count
        report.problems += duplicates(lines)
        report.problems += conflicts(lines)

        let index = ArchiveIndex.fold(lines.map(\.value))
        report.items = index.items.count
        report.problems += index.issues.map { "does not fold: \($0)" }

        let runLog = RunLog(root: root, host: "verify")
        var runs: [JSONLines.Line<RunRecord>] = []
        if FileManager.default.fileExists(atPath: runLog.directory.path) {
            let result = try JSONLines.read(RunRecord.self, in: runLog.directory, label: "runs")
            report.problems += result.issues
            runs = result.lines
        }
        report.runs = runs.count
        report.problems += duplicates(runs)
        for line in runs where line.value.end < line.value.start { report.problems.append("\(line.location): run ends before it starts") }
        let logged = Set(runs.map(\.value.run))
        let unlogged = Set(lines.map(\.value.run)).subtracting(logged)
        if !unlogged.isEmpty {
            // The ledger is appended before the run log, so an interrupted run leaves events without a run line.
            report.notes.append("\(unlogged.count) run(s) in the ledger have no run log line, such as an interrupted run: \(unlogged.sorted().prefix(3).joined(separator: ", "))")
        }

        if let cacheRoot { checkCache(ledger, index: index, cacheRoot: cacheRoot, report: &report) }
        // TODO: once the phase 5 views land, re-render each view from the fold and report files whose digest differs.
        return report
    }

    /// Byte-identical lines: harmless to the fold, but the writer never appends the same event twice.
    static func duplicates<Value: Encodable>(_ lines: [JSONLines.Line<Value>]) -> [String] {
        var seen: [Data: [String]] = [:]
        var order: [Data] = []
        for line in lines {
            guard let data = try? JSONLines.encoder.encode(line.value) else { continue }
            if seen[data] == nil { order.append(data) }
            seen[data, default: []].append(line.location)
        }
        return order.compactMap { data in
            let locations = seen[data]!
            return locations.count > 1 ? "duplicate line at \(locations.joined(separator: ", "))" : nil
        }
    }

    /// One run adds a key at most once and moves it to one new key. Later reads in the same run (several AI
    /// export zips) change or tombstone it instead, so other event types may repeat.
    static func conflicts(_ lines: [JSONLines.Line<LedgerEvent>]) -> [String] {
        let groups = Dictionary(grouping: lines.filter { $0.value.type == .added || $0.value.type == .rekeyed }) {
            "\($0.value.run) \($0.value.type.rawValue) \($0.value.key.source.rawValue)/\($0.value.key.id)"
        }
        return groups.keys.sorted().compactMap { group in
            let lines = groups[group]!
            let distinct = Set(lines.compactMap { try? JSONLines.encoder.encode($0.value) })
            guard distinct.count > 1 else { return nil }
            let event = lines[0].value
            return "conflicting \(event.type.rawValue) events for \(event.key.source.rawValue)/\(event.key.id) in run \(event.run) at \(lines.map(\.location).joined(separator: ", "))"
        }
    }

    /// The cache is trusted while the ledger files match its stamps, so it must then equal a fresh fold.
    static func checkCache(_ ledger: Ledger, index: ArchiveIndex, cacheRoot: URL, report: inout VerifyReport) {
        let url = ArchiveIndex.cacheFile(for: ledger, in: cacheRoot)
        guard let data = try? Data(contentsOf: url) else { return }
        guard let cache = try? JSONLines.decoder.decode(ArchiveIndex.Cache.self, from: data), cache.version == ArchiveIndex.Cache.currentVersion else {
            report.notes.append("The index cache \(url.path) is unreadable or outdated; the next run refolds the ledger.")
            return
        }
        guard cache.archive == ledger.root.path, cache.files == ledger.stamps() else {
            report.notes.append("The index cache is older than the ledger; the next run refolds it.")
            return
        }
        let cached = Dictionary(cache.items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let differing = Set(cached.keys).union(index.items.keys).filter { cached[$0] != index.items[$0] }.sorted()
        if cache.items.count != cached.count || !differing.isEmpty {
            let examples = differing.prefix(3).map { "\($0.source.rawValue)/\($0.id)" }.joined(separator: ", ")
            report.problems.append("The index cache disagrees with the ledger for \(differing.count) item(s) (\(examples)). Delete \(url.path) so the next run refolds.")
        }
    }
}
