import Foundation

/// The menu bar icon's state, most urgent first when several apply: running, paused, failed, attention, idle.
public enum IconState: String, CaseIterable {
    case idle, running, attention, paused, failed
}

/// One source's row in the menu, from its newest run log record.
public struct SourceStatus: Equatable {
    public enum State: Equatable { case ok, reading, failed }
    public var source: ArchiveSource
    public var state: State
    /// `14:31`, `reading…`, or the read's first warning.
    public var detail: String
}

/// What the menu shows, from the run log, the scheduler and the health check, so the app and `_index.md` agree.
public struct MenuStatus: Equatable {
    public var icon: IconState
    public var sources: [SourceStatus]
    public var warnings: [String]

    /// `failure` is a run that archived nothing (it could not start, timed out, or was refused); a run where only some
    /// sources failed shows in their rows and turns the icon to attention instead.
    public static func make(records: [RunRecord], now: Date, running: Lane?, reading: ArchiveSource?, pausedUntil: Date?, failure: String?,
                            health: [String], time: (Date) -> String) -> MenuStatus {
        var latest: [ArchiveSource: RunRecord] = [:]
        for record in records where record.end >= (latest[record.source]?.end ?? .distantPast) { latest[record.source] = record }
        let shown = ArchiveReaders.order.filter { latest[$0] != nil || $0 == reading }
        let sources = shown.map { source -> SourceStatus in
            if source == reading { return SourceStatus(source: source, state: .reading, detail: "reading…") }
            let record = latest[source]!
            return record.complete
                ? SourceStatus(source: source, state: .ok, detail: time(record.end))
                : SourceStatus(source: source, state: .failed, detail: "\(time(record.end)): \(record.warnings.first ?? "partial read")")
        }
        var warnings = health
        if let failure { warnings.insert("Last run failed: \(failure)", at: 0) }
        let icon: IconState
        if running != nil { icon = .running }
        else if let pausedUntil, pausedUntil > now { icon = .paused }
        else if failure != nil { icon = .failed }
        else if !health.isEmpty || sources.contains(where: { $0.state == .failed }) { icon = .attention }
        else { icon = .idle }
        return MenuStatus(icon: icon, sources: sources, warnings: warnings)
    }
}
