import Foundation

/// How one source is read in one run.
public enum ReadMode: String, Codable {
    /// The source has no complete backfill or full sweep yet: everything since `--backfill-since`.
    case backfill
    /// The last complete full read is older than `--full-sweep-days`: everything again, so old deletions show.
    case full
    /// Only recent history (`--rescan-days`).
    case rescan
    /// New ChatGPT or Claude export zips from the inbox.
    case `import`
    /// New lines of Claude Code transcripts.
    case incremental
    /// Synthetic data from `archive --demo`.
    case demo
}

public struct ArchiveReadRequest {
    public var mode: ReadMode
    public var now: Date
    /// Start of the read window: `--backfill-since` on backfill and full sweeps, else the rescan cutoff.
    public var from: Date
    /// End of the calendar window.
    public var until: Date
    /// Set on backfill and full sweeps: items dated earlier are outside every read and become `archived`.
    public var liveFrom: Date?
    /// This source's current items, for readers that return only what is new.
    public var previous: [ItemKey: ArchivedItem]
    /// Digests of AI export zips that are already in the run log.
    public var importedDigests: Set<String>
}

/// What one read returned. Each read becomes one observation and one run log line.
public struct ArchiveRead {
    public var payloads: [ArchivePayload]
    public var scope: Scope
    /// False when the read was partial. Such reads add and change items but never count as evidence of absence.
    public var complete: Bool
    public var warnings: [String]
    public var digest: String?
    /// Runs after the ledger append succeeded, such as saving read cursors. A failed append must be read again.
    public var commit: (() throws -> Void)?

    public init(payloads: [ArchivePayload], scope: Scope, complete: Bool = true, warnings: [String] = [], digest: String? = nil, commit: (() throws -> Void)? = nil) {
        self.payloads = payloads; self.scope = scope; self.complete = complete; self.warnings = warnings; self.digest = digest; self.commit = commit
    }
}

/// One source's reader. Tests and the demo inject fakes.
@MainActor
public protocol ArchiveReader {
    var source: ArchiveSource { get }
    /// Readers that are not window-based (AI imports, Claude Code) name their own mode.
    var fixedMode: ReadMode? { get }
    /// No reads means nothing new, such as an inbox without new exports. Several reads are merged in order.
    func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead]
}

public struct ArchiveOptions {
    public var backfillSince: Date
    public var rescanDays: Int
    public var fullSweepDays: Int
    /// Calendar lookahead on every read.
    public var futureDays = 730

    public init(backfillSince: Date, rescanDays: Int, fullSweepDays: Int) {
        self.backfillSince = backfillSince; self.rescanDays = rescanDays; self.fullSweepDays = fullSweepDays
    }

    public init(_ config: Config) { self.init(backfillSince: config.backfillSince, rescanDays: config.rescanDays, fullSweepDays: config.fullSweepDays) }
}

public struct ArchiveSummary {
    public struct Line {
        public var source: ArchiveSource
        public var mode: ReadMode
        public var complete: Bool
        public var counts: [String: Int]
        public var warnings: [String]
    }

    public var lines: [Line] = []
    public var failures: [ArchiveSource: String] = [:]

    public init() {}

    func total(_ keys: [String]) -> Int { lines.reduce(0) { sum, line in sum + keys.reduce(0) { $0 + (line.counts[$1] ?? 0) } } }
    public var added: Int { total(["added"]) }
    public var changed: Int { total(["changed"]) }
    /// Newly deleted, expired or unknown.
    public var tombstoned: Int { total(LifecycleState.allCases.filter(\.isTombstone).map { "stateChanged.\($0.rawValue)" }) }
    public var revoked: Int { total(["stateChanged.revoked"]) }
    public var pending: Int { total(["missingPending"]) }
    public var warnings: [String] { lines.flatMap { line in line.warnings.map { "\(line.source.rawValue): \($0)" } } }
}

/// One `archive` run: per source, choose a read mode, read, merge, append to the ledger and the run log.
/// A failed source is logged as incomplete and the others continue, as in the `export` loop.
@MainActor
public final class Archiver {
    public let ledger: Ledger
    public let runLog: RunLog
    public private(set) var index: ArchiveIndex
    public let options: ArchiveOptions
    let cacheRoot: URL?
    let timeZone: TimeZone

    public init(ledger: Ledger, runLog: RunLog, index: ArchiveIndex, options: ArchiveOptions, cacheRoot: URL? = ArchiveIndex.defaultCacheRoot, timeZone: TimeZone = .current) {
        self.ledger = ledger; self.runLog = runLog; self.index = index; self.options = options; self.cacheRoot = cacheRoot; self.timeZone = timeZone
    }

    /// `demo` marks the archive as synthetic: a real run refuses a demo archive and a demo refuses a real one.
    public func run(_ readers: [ArchiveReader], now: Date, demo: Bool = false) async throws -> ArchiveSummary {
        var records = try runLog.read().records
        if demo, records.contains(where: { $0.mode != ReadMode.demo.rawValue }) || (records.isEmpty && !index.items.isEmpty) {
            throw ExportError.message("The demo needs an empty archive folder; this one holds a real archive.")
        }
        if !demo, records.contains(where: { $0.mode == ReadMode.demo.rawValue }) {
            throw ExportError.message("This archive folder holds demo data. Choose a new folder for the real archive.")
        }
        // Run log times follow `now`, so tests and the demo can move the clock; the elapsed part is real.
        let started = Date()
        func end() -> Date { now.addingTimeInterval(max(0, Date().timeIntervalSince(started))) }
        let runID = "\(JSONLines.timestamp.string(from: now))-\(ledger.host)"
        let imported = Set(records.compactMap(\.digest))
        var summary = ArchiveSummary()
        var cacheValid = true

        for reader in readers {
            let source = reader.source
            let mode = reader.fixedMode ?? Self.mode(for: source, records: records, now: now, options: options)
            let request = self.request(mode, now: now, source: source, imported: imported)
            ExportLog.info("\(source.rawValue): \(mode.rawValue) read")
            var appending = false
            do {
                for read in try await reader.read(request) {
                    let items = StableKey.items(read.payloads, at: now) { Self.partition(of: $0, fallback: now, timeZone: self.timeZone) }
                    let observation = Observation(source: source, runID: runID, at: now, complete: read.complete, scope: read.scope, items: items)
                    let result = Merger.merge(index, observation)
                    appending = true
                    try ledger.append(result.events)
                    for event in result.events { index.apply(event) }
                    appending = false
                    let warnings = read.warnings + result.warnings
                    let record = RunRecord(run: runID, source: source, start: now, end: end(), complete: read.complete, scope: read.scope.summary,
                                           counts: result.counts, warnings: warnings, mode: mode.rawValue, digest: read.digest)
                    try runLog.append([record])
                    records.append(record)
                    summary.lines.append(.init(source: source, mode: mode, complete: read.complete, counts: result.counts, warnings: warnings))
                    do { try read.commit?() } catch {
                        summary.lines[summary.lines.count - 1].warnings.append("could not save the read position: \(error.localizedDescription)")
                    }
                }
            } catch {
                // A half-written append leaves the in-memory index behind the ledger; the next run refolds.
                if appending { cacheValid = false }
                let message = error.localizedDescription
                summary.failures[source] = message
                let record = RunRecord(run: runID, source: source, start: now, end: end(), complete: false, scope: "read failed",
                                       warnings: [message], mode: mode.rawValue)
                do { try runLog.append([record]); records.append(record) } catch {
                    ExportLog.info("could not log the failed \(source.rawValue) run: \(error.localizedDescription)")
                }
            }
        }
        if cacheValid { index.save(ledger, cacheRoot: cacheRoot) }
        try Data(Self.indexPage(index: index, records: records, now: now).utf8).write(to: ledger.root.appendingPathComponent(Self.indexPageName), options: .atomic)
        return summary
    }

    func request(_ mode: ReadMode, now: Date, source: ArchiveSource, imported: Set<String>) -> ArchiveReadRequest {
        let calendar = Calendar.current
        let sweep = mode == .backfill || mode == .full
        return ArchiveReadRequest(
            mode: mode, now: now,
            from: sweep ? options.backfillSince : calendar.date(byAdding: .day, value: -options.rescanDays, to: now)!,
            until: calendar.date(byAdding: .day, value: options.futureDays, to: now)!,
            liveFrom: sweep ? options.backfillSince : nil,
            previous: index.items.filter { $0.key.source == source },
            importedDigests: imported)
    }

    /// Backfill until the source has a complete backfill or full sweep, a full sweep once the last one
    /// is `fullSweepDays` old, else a rescan.
    public static func mode(for source: ArchiveSource, records: [RunRecord], now: Date, options: ArchiveOptions) -> ReadMode {
        let sweeps = records.filter { $0.source == source && $0.complete && ($0.mode == ReadMode.backfill.rawValue || $0.mode == ReadMode.full.rawValue) }
        guard let last = sweeps.map(\.start).max() else { return .backfill }
        return now.timeIntervalSince(last) >= TimeInterval(options.fullSweepDays) * 86_400 ? .full : .rescan
    }

    /// The civil date an item belongs to, with the UTC offset that produced it (decision 15). The ledger only
    /// needs it to be stable; phase 5 lays out the views by it.
    public static func partition(of payload: ArchivePayload, fallback: Date, timeZone: TimeZone = .current) -> Partition {
        var zone = timeZone
        let date: Date
        switch payload {
        case .note(let note): date = note.modified ?? note.created ?? fallback
        case .reminder(let reminder): date = reminder.completionDate ?? reminder.created ?? fallback
        case .event(let event):
            if event.isAllDay, let day = event.startDate { return Partition(date: day, utcOffset: timeZone.secondsFromGMT(for: event.start)) }
            if let identifier = event.timeZone, let eventZone = TimeZone(identifier: identifier) { zone = eventZone }
            date = event.start
        case .message(let value): date = value.message.timestamp
        case .aiMessage(let value): date = value.message.timestamp ?? fallback
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return Partition(date: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!), utcOffset: zone.secondsFromGMT(for: date))
    }

    public static let indexPageName = "_index.md"

    /// Minimal status page until the views of phase 5. Rewritten whole on every run.
    public static func indexPage(index: ArchiveIndex, records: [RunRecord], now: Date) -> String {
        func time(_ date: Date) -> String { JSONLines.timestamp.string(from: date) }
        let complete = RunLog.lastComplete(records)
        var latest: [ArchiveSource: RunRecord] = [:]
        for record in records where record.end >= (latest[record.source]?.end ?? .distantPast) { latest[record.source] = record }
        let items = Dictionary(grouping: index.items.values, by: \.key.source)
        var lines = [
            "# Archive", "",
            "Updated \(time(now)). The ledger in `\(Ledger.folderName)/` is the source of truth; this page is rewritten on every run.", "",
            "| Source | Last complete read | Mode | Items | Gone | Pending |",
            "|---|---|---|---:|---:|---:|",
        ]
        for source in ArchiveSource.allCases where latest[source] != nil || items[source] != nil {
            let all = items[source] ?? []
            let gone = all.filter { $0.state.isTombstone || $0.state == .revoked }.count
            let pending = all.filter { $0.missingSince != nil }.count
            let last = complete[source]
            lines.append("| \(source.displayName) | \(last.map { time($0.end) } ?? "never") | \(last?.mode ?? "–") | \(all.count) | \(gone) | \(pending) |")
        }
        let problems = latest.values.filter { !$0.complete }.sorted { $0.source.rawValue < $1.source.rawValue }
        if !problems.isEmpty {
            lines += ["", "## Last read incomplete", ""]
            for record in problems { lines.append("- \(record.source.displayName), \(time(record.end)): \(record.warnings.first ?? "partial read")") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
