import Foundation

/// One line per source per run. `last_seen` is derived from complete runs, so the ledger never rewrites items.
public struct RunRecord: Codable, Equatable {
    public var v: Int
    public var run: String
    public var source: ArchiveSource
    public var start, end: Date
    /// False when the read failed or was partial; such runs never count as evidence of absence.
    public var complete: Bool
    public var scope: String
    public var counts: [String: Int]
    public var warnings: [String]
    /// How the source was read, such as `backfill`, `full`, `rescan`, `import` or `demo` (`ReadMode`).
    public var mode: String?
    /// SHA-256 of an imported AI export zip, so the same export is never imported twice.
    public var digest: String?

    public init(run: String, source: ArchiveSource, start: Date, end: Date, complete: Bool, scope: String, counts: [String: Int] = [:], warnings: [String] = [],
                mode: String? = nil, digest: String? = nil) {
        v = 1; self.run = run; self.source = source; self.start = start; self.end = end
        self.complete = complete; self.scope = scope; self.counts = counts; self.warnings = warnings
        self.mode = mode; self.digest = digest
    }
}

extension RunRecord: Timestamped { var at: Date { end } }

/// `.archive/runs/<YYYY-MM>.<host>.jsonl`, partitioned by run end month.
public struct RunLog {
    public let root: URL
    public let host: String

    public init(root: URL, host: String) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.host = host
    }

    public var directory: URL { root.appendingPathComponent(Ledger.folderName).appendingPathComponent("runs") }

    public func append(_ records: [RunRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (month, batch) in Dictionary(grouping: records, by: { JSONLines.month($0.end) }).sorted(by: { $0.key < $1.key }) {
            try JSONLines.append(try batch.map { try JSONLines.encoder.encode($0) }, to: directory.appendingPathComponent("\(month).\(host).jsonl"))
        }
    }

    public func read() throws -> (records: [RunRecord], issues: [String]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        let result = try JSONLines.read(RunRecord.self, in: directory, label: "runs")
        return (JSONLines.merged(result.lines).map(\.value), result.issues)
    }

    /// Latest complete run per source, the basis for `last_seen` and health checks.
    public static func lastComplete(_ records: [RunRecord]) -> [ArchiveSource: RunRecord] {
        var latest: [ArchiveSource: RunRecord] = [:]
        for record in records where record.complete && record.end >= (latest[record.source]?.end ?? .distantPast) { latest[record.source] = record }
        return latest
    }
}
