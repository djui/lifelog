import Foundation

/// A group of sources the menu bar app archives together on one interval, like one launchd agent did.
public struct Lane: Hashable, Identifiable {
    public var id: String
    public var name: String
    public var sources: [ArchiveSource]
    public var interval: TimeInterval

    /// WhatsApp's shortest disappearing timer is 24 h, so it is read often.
    public static let frequent = Lane(id: "frequent", name: "Frequent", sources: [.reminders, .calendar, .whatsapp, .claudecode], interval: 600)
    /// A full Notes read can take minutes.
    public static let hourly = Lane(id: "hourly", name: "Hourly", sources: [.chatgpt, .claude, .notes], interval: 3600)
    public static let all = [frequent, hourly]

    /// Arguments for one archive run of this lane, as the CLI takes them.
    public func arguments(output: URL) -> [String] {
        ["archive", "--output", output.path, "--sources", sources.map(\.rawValue).joined(separator: ",")]
    }
}

/// When each lane is due. Pure, so the menu bar app's timer, wake handling and pause are tested with a fake clock.
public enum Schedule {
    /// A tick fires about once a minute; a lane counts as due this much early, so its runs don't drift a minute later each time.
    public static let slack: TimeInterval = 30

    /// A lane's last run: the newest run log record of any of its sources, complete or not, or a later attempt the
    /// app made itself (a run that logged nothing, such as Claude Code with no new lines).
    public static func lastRun(_ lane: Lane, records: [RunRecord], attempted: Date? = nil) -> Date? {
        let logged = records.filter { lane.sources.contains($0.source) }.map(\.start).max()
        return [logged, attempted].compactMap { $0 }.max()
    }

    public static func due(_ lanes: [Lane], now: Date, last: [String: Date], pausedUntil: Date? = nil) -> [Lane] {
        if let pausedUntil, pausedUntil > now { return [] }
        return lanes.filter { lane in last[lane.id].map { now.timeIntervalSince($0) >= lane.interval - slack } ?? true }
    }

    /// The next time a lane is due, or nil when one is due now.
    public static func next(_ lanes: [Lane], now: Date, last: [String: Date], pausedUntil: Date? = nil) -> Date? {
        let times = lanes.map { lane in last[lane.id].map { $0 + lane.interval } ?? now }
        guard let soonest = times.min() else { return nil }
        let at = max(soonest, pausedUntil ?? soonest)
        return at > now ? at : nil
    }
}

/// The launchd agents from the README. While one is installed, the menu bar app leaves scheduling to it, so the
/// same sources are not read twice.
public enum LaunchAgents {
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents") }

    /// Installed archive agents (`com.djui.icloud-exporter.archive*.plist`); the export agent does not count.
    public static func archiveAgents(in directory: URL = directory) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("com.djui.icloud-exporter.archive") && $0.hasSuffix(".plist") }.sorted()
    }
}
