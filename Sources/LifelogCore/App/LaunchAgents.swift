import Foundation

/// The launchd agents from the README. While an archive agent is installed, the menu bar app leaves scheduling to
/// it, so the same sources are not read twice; the app can take over its folder and schedule instead.
public enum LaunchAgents {
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents") }
    /// Agents of this app; `com.djui.icloud-exporter` is its name before the rename to Lifelog.
    static let prefixes = ["com.djui.lifelog", "com.djui.icloud-exporter"]

    /// One installed agent.
    public struct Agent: Equatable {
        public var file: URL
        public var label: String
        /// The CLI arguments, without the executable.
        public var arguments: [String]
        public var interval: Int?
        public var isArchive: Bool { arguments.first == Command.archive.rawValue }
    }

    /// Installed archive agents (`com.djui.lifelog.archive*.plist`, or the old name's); the export agent does not count.
    public static func archiveAgents(in directory: URL = directory) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { name in prefixes.contains { name.hasPrefix($0 + ".archive") } && name.hasSuffix(".plist") }.sorted()
    }

    /// Every installed agent of this app that can be read.
    public static func agents(in directory: URL = directory) -> [Agent] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { name in prefixes.contains { name.hasPrefix($0 + ".") } && name.hasSuffix(".plist") }
        return names.sorted().compactMap { name in
            let file = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let program = plist["ProgramArguments"] as? [String], !program.isEmpty else { return nil }
            return Agent(file: file, label: plist["Label"] as? String ?? name, arguments: Array(program.dropFirst()), interval: plist["StartInterval"] as? Int)
        }
    }

    /// Settings and the archive folder that reproduce the archive agents: the agent with the shortest interval becomes
    /// the frequent schedule and the others the hourly one, sources no agent read are turned off, and the agents'
    /// options carry over. Nil when no archive agent can be read.
    public static func adopt(_ agents: [Agent], into base: AppSettings) -> (settings: AppSettings, folder: URL)? {
        let archive = agents.filter(\.isArchive).compactMap { agent in (try? Config(arguments: agent.arguments)).map { (agent, $0) } }
            .sorted { ($0.0.interval ?? .max) < ($1.0.interval ?? .max) }
        guard let (fastAgent, fast) = archive.first else { return nil }
        var settings = base
        settings.sourceLanes = Dictionary(uniqueKeysWithValues: ArchiveSource.allCases.map { ($0, AppSettings.off) })
        for (index, (agent, config)) in archive.enumerated() {
            let lane = index == 0 ? Lane.frequent.id : Lane.hourly.id
            for source in config.sources where settings.sourceLanes[source] == AppSettings.off { settings.sourceLanes[source] = lane }
            if let interval = agent.interval {
                let minutes = interval / 60
                if index == 0 { settings.frequentMinutes = nearest(minutes, in: AppSettings.frequentChoices) }
                else { settings.hourlyMinutes = nearest(minutes, in: AppSettings.hourlyChoices) }
            }
        }
        let cli = try! Config(arguments: ["archive", "--output", fast.output.path])
        settings.aiInbox = fast.aiInbox == cli.aiInbox ? nil : fast.aiInbox
        settings.backfillSince = value(of: "--backfill-since", in: fastAgent.arguments)
        settings.rescanDays = fast.rescanDays
        settings.fullSweepDays = fast.fullSweepDays
        settings.viewer = fast.viewer
        if archive.contains(where: { $0.1.notify }) { settings.notify = true }
        return (settings, fast.output)
    }

    static func nearest(_ minutes: Int, in choices: [Int]) -> Int { choices.min { abs($0 - minutes) < abs($1 - minutes) }! }

    static func value(of option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
}
