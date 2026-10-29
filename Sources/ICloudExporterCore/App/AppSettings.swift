import Foundation

/// The menu bar app's settings, kept in UserDefaults. Every archive option the CLI takes has a setting here, and
/// `arguments(for:output:)` turns them into the same `archive` arguments, so an app run and a CLI run read alike.
public struct AppSettings: Equatable {
    public static let frequentChoices = [5, 10, 15, 30]
    public static let hourlyChoices = [30, 60, 120, 240]
    public static let off = "off"

    public var notify = true
    public var frequentMinutes = 10
    public var hourlyMinutes = 60
    public var runOnWake = true
    public var deferOnBattery = false
    /// Source → lane id (`frequent`, `hourly`) or `off`. Sources not listed use their default lane.
    public var sourceLanes: [ArchiveSource: String] = [:]
    /// Nil uses the CLI default, `~/Downloads`.
    public var aiInbox: URL?
    /// `YYYY-MM-DD`; nil uses the CLI default.
    public var backfillSince: String?
    public var rescanDays = 100
    public var fullSweepDays = 7
    public var viewer = true

    public init() {}

    /// A source's lane id, or `off`.
    public func lane(of source: ArchiveSource) -> String {
        sourceLanes[source] ?? (Lane.frequent.sources.contains(source) ? Lane.frequent.id : Lane.hourly.id)
    }

    /// The lanes with their intervals and sources; a lane without sources is left out.
    public var lanes: [Lane] {
        Lane.all.compactMap { base in
            var lane = base
            lane.interval = TimeInterval(base.id == Lane.frequent.id ? frequentMinutes : hourlyMinutes) * 60
            lane.sources = ArchiveReaders.order.filter { self.lane(of: $0) == base.id }
            return lane.sources.isEmpty ? nil : lane
        }
    }

    /// `archive` arguments for one lane, with every option that differs from the CLI's default.
    public func arguments(for lane: Lane, output: URL) -> [String] {
        var arguments = lane.arguments(output: output)
        if let aiInbox { arguments += ["--ai-inbox", aiInbox.path] }
        if let backfillSince { arguments += ["--backfill-since", backfillSince] }
        if rescanDays != 100 { arguments += ["--rescan-days", String(rescanDays)] }
        if fullSweepDays != 7 { arguments += ["--full-sweep-days", String(fullSweepDays)] }
        if !viewer { arguments.append("--no-viewer") }
        return arguments + ["--progress"]
    }

    enum Key {
        static let notify = "notify", frequentMinutes = "frequentMinutes", hourlyMinutes = "hourlyMinutes", runOnWake = "runOnWake"
        static let deferOnBattery = "deferOnBattery", sourceLanes = "sourceLanes", aiInbox = "aiInbox", backfillSince = "backfillSince"
        static let rescanDays = "rescanDays", fullSweepDays = "fullSweepDays", viewer = "viewer"
    }

    /// Unset or invalid values keep their defaults.
    public static func load(_ defaults: UserDefaults) -> AppSettings {
        var settings = AppSettings()
        func bool(_ key: String) -> Bool? { defaults.object(forKey: key) as? Bool }
        func int(_ key: String, in range: ClosedRange<Int>) -> Int? { (defaults.object(forKey: key) as? Int).flatMap { range.contains($0) ? $0 : nil } }
        settings.notify = bool(Key.notify) ?? settings.notify
        settings.runOnWake = bool(Key.runOnWake) ?? settings.runOnWake
        settings.deferOnBattery = bool(Key.deferOnBattery) ?? settings.deferOnBattery
        settings.viewer = bool(Key.viewer) ?? settings.viewer
        settings.frequentMinutes = int(Key.frequentMinutes, in: 1...1440) ?? settings.frequentMinutes
        settings.hourlyMinutes = int(Key.hourlyMinutes, in: 1...1440) ?? settings.hourlyMinutes
        settings.rescanDays = int(Key.rescanDays, in: 1...730) ?? settings.rescanDays
        settings.fullSweepDays = int(Key.fullSweepDays, in: 1...730) ?? settings.fullSweepDays
        let lanes = Set(Lane.all.map(\.id) + [off])
        for (name, lane) in defaults.dictionary(forKey: Key.sourceLanes) as? [String: String] ?? [:] {
            if let source = ArchiveSource(rawValue: name), lanes.contains(lane) { settings.sourceLanes[source] = lane }
        }
        settings.aiInbox = defaults.string(forKey: Key.aiInbox).map { URL(fileURLWithPath: $0, isDirectory: true) }
        settings.backfillSince = defaults.string(forKey: Key.backfillSince).flatMap { Config.civilDate($0) != nil ? $0 : nil }
        return settings
    }

    public func save(_ defaults: UserDefaults) {
        defaults.set(notify, forKey: Key.notify)
        defaults.set(runOnWake, forKey: Key.runOnWake)
        defaults.set(deferOnBattery, forKey: Key.deferOnBattery)
        defaults.set(viewer, forKey: Key.viewer)
        defaults.set(frequentMinutes, forKey: Key.frequentMinutes)
        defaults.set(hourlyMinutes, forKey: Key.hourlyMinutes)
        defaults.set(rescanDays, forKey: Key.rescanDays)
        defaults.set(fullSweepDays, forKey: Key.fullSweepDays)
        defaults.set(Dictionary(uniqueKeysWithValues: sourceLanes.map { ($0.key.rawValue, $0.value) }), forKey: Key.sourceLanes)
        defaults.set(aiInbox?.path, forKey: Key.aiInbox)
        defaults.set(backfillSince, forKey: Key.backfillSince)
    }
}
