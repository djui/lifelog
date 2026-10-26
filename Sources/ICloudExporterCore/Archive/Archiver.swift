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
    /// Archive pages written after the merge.
    public var pages = ExportSummary()
    /// Set when the pages could not be written. The ledger is already up to date; `rebuild` retries the pages.
    public var pageError: String?

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
    /// Warnings for the "Health" section of `_index.md`, from the run log after the run (phase 6).
    public var health: (_ records: [RunRecord], _ now: Date) -> [String] = { _, _ in [] }

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
        let before = index
        var touched = Set<ItemKey>()

        for reader in readers {
            let source = reader.source
            let mode = reader.fixedMode ?? Self.mode(for: source, records: records, now: now, options: options)
            let request = self.request(mode, now: now, source: source, imported: imported)
            ExportLog.info("\(source.rawValue): \(mode.rawValue) read")
            var appending = false
            do {
                for read in try await reader.read(request) {
                    let items = StableKey.items(read.payloads, at: now) { Partition.of($0, fallback: now, timeZone: self.timeZone) }
                    let observation = Observation(source: source, runID: runID, at: now, complete: read.complete, scope: read.scope, items: items)
                    let result = Merger.merge(index, observation)
                    appending = true
                    try ledger.append(result.events)
                    // Apply what the ledger holds (millisecond timestamps), not the in-memory values, so pages
                    // rendered now are byte for byte what `rebuild` renders from a fresh fold.
                    for event in try JSONLines.stored(result.events) {
                        index.apply(event)
                        touched.insert(event.key)
                        if let newKey = event.newKey { touched.insert(newKey) }
                    }
                    appending = false
                    let warnings = read.warnings + result.warnings
                    let record = RunRecord(run: runID, source: source, start: now, end: end(), complete: read.complete, scope: read.scope.summary,
                                           counts: result.counts, warnings: warnings, mode: mode.rawValue, digest: read.digest, timeZone: timeZone.identifier)
                    try runLog.append([record])
                    records += try JSONLines.stored([record])
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
                                       warnings: [message], mode: mode.rawValue, timeZone: timeZone.identifier)
                do { try runLog.append([record]); records += try JSONLines.stored([record]) } catch {
                    ExportLog.info("could not log the failed \(source.rawValue) run: \(error.localizedDescription)")
                }
            }
        }
        if cacheValid { index.save(ledger, cacheRoot: cacheRoot) }
        // Only pages showing an item this run touched are rendered; the rest stay as they are.
        let context = ViewContext(index: index, records: records, now: now, timeZone: timeZone, demo: demo, health: health(records, now))
        do { summary.pages = try ArchivePages.write(context, to: ExportStore(output: ledger.root, layout: .archive), before: before, touched: touched) }
        catch { summary.pageError = error.localizedDescription }
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

    /// Regenerates every page from the ledger. Pages that are no longer produced are removed; unchanged ones are not rewritten.
    public static func rebuild(_ ledger: Ledger, runLog: RunLog, index: ArchiveIndex, now: Date, timeZone: TimeZone = .current, health: [String] = []) throws -> ExportSummary {
        let records = try runLog.read().records
        let demo = records.contains { $0.mode == ReadMode.demo.rawValue }
        let context = ViewContext(index: index, records: records, now: now, timeZone: timeZone, demo: demo, health: health)
        return try ArchivePages.write(context, to: ExportStore(output: ledger.root, layout: .archive))
    }
}
