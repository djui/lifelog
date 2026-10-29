import AppKit
import Foundation
import ICloudExporterCore
import IOKit.ps

/// Runs each lane's archive when it is due (menu bar plan, PR 2). Every run is a child process of this same
/// executable with CLI arguments, so a slow Notes read or a crash never blocks the menu, the CLI stays the one code
/// path, and macOS attributes the run's data access to this app. Runs go one at a time; the archive lock keeps them
/// apart from a run started in Terminal.
@MainActor
final class Scheduler: ObservableObject {
    static let pausedKey = "pausedUntil"

    @Published private(set) var running: Lane?
    /// The source the running lane reads now, from the child's `--progress` lines.
    @Published private(set) var reading: ArchiveSource?
    @Published private(set) var lastRun: [String: Date] = [:]
    @Published private(set) var records: [RunRecord] = []
    /// A run that archived nothing (it could not start, timed out, or was refused); sources that failed in a run show
    /// in the run log instead.
    @Published private(set) var failure: String?
    /// The same warnings as the "Health" section of `_index.md`.
    @Published private(set) var health: [String] = []
    @Published private(set) var pausedUntil: Date?
    /// Installed launchd archive agents. While there are any, they do the scheduling.
    @Published private(set) var agents: [String] = []

    var folder: URL? { didSet { tick() } }
    private var attempted: [String: Date] = [:]
    private var requested: [Lane] = []
    private var timer: Timer?
    private var notifying = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pausedUntil = (defaults.object(forKey: Self.pausedKey) as? Date).flatMap { $0 > Date() ? $0 : nil }
    }

    var settings: AppSettings { AppSettings.load(defaults) }

    var next: Date? { Schedule.next(settings.lanes, now: Date(), last: lastRun, pausedUntil: pausedUntil) }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        // Catch up right after wake instead of waiting for the next minute; disks and networks need a moment.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.settings.runOnWake == true else { return }
                try? await Task.sleep(for: .seconds(10))
                self?.tick()
            }
        }
        tick()
    }

    /// Every lane now, also while paused.
    func runNow() {
        requested = settings.lanes
        tick()
    }

    func pause(for interval: TimeInterval?) {
        pausedUntil = interval.map { Date() + $0 }
        defaults.set(pausedUntil, forKey: Self.pausedKey)
        tick()
    }

    func tick() {
        agents = LaunchAgents.archiveAgents()
        guard let folder else { return }
        let settings = settings
        let lanes = settings.lanes
        records = (try? RunLog(root: folder, host: "app").read().records) ?? []
        lastRun = Dictionary(uniqueKeysWithValues: lanes.compactMap { lane in
            Schedule.lastRun(lane, records: records, attempted: attempted[lane.id]).map { (lane.id, $0) }
        })
        checkHealth(folder)
        if let pausedUntil, pausedUntil <= Date() { pause(for: nil); return }
        guard running == nil, agents.isEmpty else { return }
        var scheduled = Schedule.due(lanes, now: Date(), last: lastRun, pausedUntil: pausedUntil).filter { lane in !requested.contains { $0.id == lane.id } }
        // On battery the hourly lane waits for power, if the user asked for that; Run Now still runs it.
        if settings.deferOnBattery, Self.onBattery { scheduled.removeAll { $0.id == Lane.hourly.id } }
        let due = requested + scheduled
        guard let lane = due.first else { return }
        // A run from Terminal holds the lock: try again at the next tick.
        guard !Self.locked(folder) else { return }
        requested.removeAll { $0.id == lane.id }
        let started = Date()
        attempted[lane.id] = started
        running = lane
        Task {
            let result = await Runner.run(settings.arguments(for: lane, output: folder), timeout: lane.interval * 3) { step in
                Task { @MainActor in self.reading = step.progress == .reading ? step.source : nil }
            }
            running = nil
            reading = nil
            let logged = ((try? RunLog(root: folder, host: "app").read().records) ?? []).contains { $0.start >= started - 1 }
            failure = result.status == 0 || logged ? nil : result.problem ?? "The run archived nothing."
            tick()
        }
    }

    /// Health warnings for the menu, and their notifications (decision 17). Notices already sent by this app or by
    /// `archive --notify` share one record in the archive's cache folder, so each is sent once. A demo archive's clock
    /// is synthetic, so it gets no health check, as in the CLI.
    func checkHealth(_ folder: URL) {
        guard !records.isEmpty, !records.contains(where: { $0.mode == ReadMode.demo.rawValue }) else { health = []; return }
        let report = Health.report(records, now: Date(), whatsAppRunning: Health.whatsAppRunning())
        health = report.warnings
        guard !notifying, !report.notices.isEmpty, AppSettings.load(defaults).notify,
              let cacheRoot = ArchiveIndex.defaultCacheRoot else { return }
        let sent = ArchiveIndex.cacheDirectory(for: Ledger(root: folder, host: "app"), in: cacheRoot).appendingPathComponent(SentNotices.fileName)
        notifying = true
        Task {
            await Notifier.send(report.notices, sentFile: sent, now: Date())
            notifying = false
        }
    }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    static func locked(_ folder: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        do { try ArchiveLock(folder.appendingPathComponent(ArchiveLock.name), owner: "archive run").release(); return false } catch { return true }
    }
}

/// One child process of this executable, with its output appended to the app's log.
enum Runner {
    struct Result {
        var status: Int32
        var problem: String?
        /// The last output line, such as a command's summary.
        var last: String? = nil
    }

    static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/iCloud Exporter/archive.log")
    }

    static func run(_ arguments: [String], timeout: TimeInterval, progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }) async -> Result {
        guard let executable = Bundle.main.executableURL else { return Result(status: -1, problem: "The app's executable is missing.") }
        let output = openLog()
        output?.write(Data("\n== \(ISO8601DateFormatter().string(from: Date())) icloud-exporter \(arguments.joined(separator: " "))\n".utf8))
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lines = LastLines(progress: progress)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            output?.write(data)
            lines.add(data)
        }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                output?.write(rest)
                lines.add(rest + Data("\n".utf8))
                try? output?.close()
                let status = process.terminationStatus
                let timedOut = process.terminationReason == .uncaughtSignal
                continuation.resume(returning: Result(status: status, problem: status == 0 ? nil : timedOut ? "The run took too long and was stopped." : lines.problem,
                                                      last: lines.last))
            }
            do { try process.run() } catch {
                try? output?.close()
                continuation.resume(returning: Result(status: -1, problem: "Could not start the archive run: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }

    /// The log, rotated to `archive.log.1` once it passes 5 MB.
    static func openLog() -> FileHandle? {
        let manager = FileManager.default
        try? manager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? manager.attributesOfItem(atPath: log.path)[.size] as? Int, size > 5_000_000 {
            let old = log.appendingPathExtension("1")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: log, to: old)
        }
        if !manager.fileExists(atPath: log.path) { manager.createFile(atPath: log.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: log)
        _ = try? handle?.seekToEnd()
        return handle
    }

    /// The child's output by line: progress steps go to `progress`, and the last lines name what went wrong.
    final class LastLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var partial = ""
        let progress: @Sendable (ArchiveProgress) -> Void

        init(progress: @escaping @Sendable (ArchiveProgress) -> Void) { self.progress = progress }

        func add(_ data: Data) {
            lock.lock()
            var parts = (partial + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
            partial = parts.removeLast()
            let complete = parts.filter { !$0.isEmpty }
            var steps: [ArchiveProgress] = []
            for line in complete {
                if let step = ArchiveProgress.parse(line) { steps.append(step) } else { lines.append(line) }
            }
            lines = Array(lines.suffix(20))
            lock.unlock()
            steps.forEach(progress)
        }

        var last: String? {
            lock.lock(); defer { lock.unlock() }
            return lines.last
        }

        /// The CLI names each failure as "Archive failed (source): …"; else the last line.
        var problem: String? {
            lock.lock(); defer { lock.unlock() }
            return lines.last { $0.contains(" failed") } ?? lines.last
        }
    }
}
