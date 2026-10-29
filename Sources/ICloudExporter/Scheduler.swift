import AppKit
import Foundation
import ICloudExporterCore

/// Runs each lane's archive when it is due (menu bar plan, PR 2). Every run is a child process of this same
/// executable with CLI arguments, so a slow Notes read or a crash never blocks the menu, the CLI stays the one code
/// path, and macOS attributes the run's data access to this app. Runs go one at a time; the archive lock keeps them
/// apart from a run started in Terminal.
@MainActor
final class Scheduler: ObservableObject {
    static let pausedKey = "pausedUntil"

    @Published private(set) var running: Lane?
    @Published private(set) var lastRun: [String: Date] = [:]
    /// The last run's problem, such as a source that could not be read; nil after a clean run.
    @Published private(set) var problem: String?
    @Published private(set) var pausedUntil: Date?
    /// Installed launchd archive agents. While there are any, they do the scheduling.
    @Published private(set) var agents: [String] = []

    var folder: URL? { didSet { tick() } }
    private var attempted: [String: Date] = [:]
    private var requested: [Lane] = []
    private var timer: Timer?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pausedUntil = (defaults.object(forKey: Self.pausedKey) as? Date).flatMap { $0 > Date() ? $0 : nil }
    }

    var next: Date? { Schedule.next(Lane.all, now: Date(), last: lastRun, pausedUntil: pausedUntil) }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        // Catch up right after wake instead of waiting for the next minute; disks and networks need a moment.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self?.tick()
            }
        }
        tick()
    }

    /// Every lane now, also while paused.
    func runNow() {
        requested = Lane.all
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
        let records = (try? RunLog(root: folder, host: "app").read().records) ?? []
        lastRun = Dictionary(uniqueKeysWithValues: Lane.all.compactMap { lane in
            Schedule.lastRun(lane, records: records, attempted: attempted[lane.id]).map { (lane.id, $0) }
        })
        if let pausedUntil, pausedUntil <= Date() { pause(for: nil); return }
        guard running == nil, agents.isEmpty else { return }
        let due = requested + Schedule.due(Lane.all, now: Date(), last: lastRun, pausedUntil: pausedUntil).filter { !requested.contains($0) }
        guard let lane = due.first else { return }
        // A run from Terminal holds the lock: try again at the next tick.
        guard !Self.locked(folder) else { return }
        requested.removeAll { $0 == lane }
        attempted[lane.id] = Date()
        running = lane
        Task {
            let result = await Runner.run(lane.arguments(output: folder), timeout: lane.interval * 3)
            running = nil
            problem = result.problem
            tick()
        }
    }

    static func locked(_ folder: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        do { try ArchiveLock(folder.appendingPathComponent(ArchiveLock.name), owner: "archive run").release(); return false } catch { return true }
    }
}

/// One child process of this executable, with its output appended to the app's log.
enum Runner {
    struct Result { var status: Int32; var problem: String? }

    static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/iCloud Exporter/archive.log")
    }

    static func run(_ arguments: [String], timeout: TimeInterval) async -> Result {
        guard let executable = Bundle.main.executableURL else { return Result(status: -1, problem: "The app's executable is missing.") }
        let output = openLog()
        output?.write(Data("\n== \(ISO8601DateFormatter().string(from: Date())) icloud-exporter \(arguments.joined(separator: " "))\n".utf8))
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lines = LastLines()
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
                lines.add(rest)
                try? output?.close()
                let status = process.terminationStatus
                let timedOut = process.terminationReason == .uncaughtSignal
                continuation.resume(returning: Result(status: status, problem: status == 0 ? nil : timedOut ? "The run took too long and was stopped." : lines.problem))
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

    /// The child's last lines, to name what went wrong in the menu.
    final class LastLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func add(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            lines += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            lines = Array(lines.suffix(20))
        }

        /// The CLI names each failure as "Archive failed (source): …"; else the last line.
        var problem: String? {
            lock.lock(); defer { lock.unlock() }
            return lines.last { $0.contains(" failed") } ?? lines.last
        }
    }
}
