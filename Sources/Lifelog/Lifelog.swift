import Foundation
import LifelogCore
import Darwin

@main
struct Lifelog {
    @MainActor
    static func main() async {
        guard case .cli(let arguments) = LaunchMode.current else {
            MenuBarApp.main()
            return
        }
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] || (arguments.count == 2 && arguments[1] == "--help" && Command(rawValue: arguments[0]) != nil) {
            print(Config.help)
            return
        }
        if arguments == ["--version"] { print("lifelog 0.1.0"); return }
        ExportLog.handler = { message in
            FileHandle.standardError.write(Data(("lifelog: \(message)\n").utf8))
        }
        let label = Command(rawValue: arguments[0]).map { $0.rawValue.prefix(1).uppercased() + $0.rawValue.dropFirst() } ?? "Export"
        do {
            let config = try Config(arguments: arguments)
            switch config.command {
            case .export: try await runExport(config)
            case .archive: try await runArchive(config)
            case .rebuild: try runRebuild(config)
            case .verify: try runVerify(config)
            case .open: try runOpen(config)
            }
        } catch {
            stderr("\(label) failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    static func runExport(_ config: Config) async throws {
        let now = Date()
        let window = config.window(now: now)
        let selected = ExportSource.allCases.filter { config.sources.contains($0) }
        ExportLog.info("starting \(config.demo ? "demo" : "live") export of \(selected.map(\.rawValue).joined(separator: ", ")) to \(config.output.path)")
        let store = ExportStore(output: config.output)
        var summary = ExportSummary()
        var failures: [ExportSource: String] = [:]
        let demo = config.demo ? Demo.snapshot(now: now) : nil
        if demo != nil { ExportLog.info("using synthetic demo data") }
        let needsEventKit = demo == nil && (config.sources.contains(.reminders) || config.sources.contains(.calendar))
        let eventKit = needsEventKit ? EventKitExporter() : nil

        // Reminders and Calendar finish quickly; WhatsApp is a local SQLite copy; Notes can take minutes.
        for source in [ExportSource.reminders, .calendar, .whatsapp, .notes] where config.sources.contains(source) {
            do {
                var snapshot = demo ?? ExportSnapshot()
                if demo == nil {
                    snapshot = try await read(source, window: window, eventKit: eventKit, config: config, now: now)
                }
                var one = config
                one.sources = [source]
                ExportLog.info("rendering \(source.rawValue)")
                let documents = try MarkdownWriter.documents(snapshot: snapshot, config: one, now: now)
                summary.merge(try store.write(documents, sources: [source], now: now, demo: config.demo, warnings: snapshot.warnings))
                for warning in snapshot.warnings[source] ?? [] { stderr("Warning (\(source.rawValue)): \(warning)") }
            } catch {
                failures[source] = error.localizedDescription
                stderr("Export failed (\(source.rawValue)): \(error.localizedDescription)")
            }
        }

        print("Export complete: \(summary.written) files written, \(summary.unchanged) unchanged, \(summary.removed) removed.")
        print("Output: \(config.output.path)")
        if !failures.isEmpty {
            let names = failures.keys.map(\.rawValue).sorted().joined(separator: ", ")
            stderr("Sources that did not export: \(names)")
            exit(1)
        }
    }

    @MainActor
    static func runArchive(_ config: Config) async throws {
        let now = Date()
        let root = config.output.resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try ArchiveLock(root.appendingPathComponent(ArchiveLock.name), owner: "archive run")
        defer { lock.release() }
        try Ledger.checkFolder(root)
        // The demo touches neither the host id nor the caches, only the output folder.
        let host = config.demo ? Demo.archiveHost : try HostID.current()
        let cacheRoot = config.demo ? nil : ArchiveIndex.defaultCacheRoot
        let ledger = Ledger(root: root, host: host)
        let index = try ArchiveIndex.load(ledger, cacheRoot: cacheRoot)
        for issue in index.issues { stderr("Warning: \(issue)") }
        let runLog = RunLog(root: root, host: host)
        if config.demo, try !index.items.isEmpty || !runLog.read().records.isEmpty {
            throw ExportError.message("The demo needs an empty archive folder.")
        }
        let archiver = Archiver(ledger: ledger, runLog: runLog, index: index, options: ArchiveOptions(config), cacheRoot: cacheRoot)
        archiver.viewer = config.viewer
        if config.progress {
            archiver.progress = { step in
                print(step.line)
                fflush(stdout)
            }
        }

        var summary = ArchiveSummary()
        if config.demo {
            ExportLog.info("archiving synthetic demo data")
            for run in Demo.archiveRuns(now: now) {
                let one = try await archiver.run(run.readers, now: run.at, demo: true)
                summary.lines += one.lines
                summary.failures.merge(one.failures) { $1 }
                summary.pages.merge(one.pages)
                summary.pageError = summary.pageError ?? one.pageError
            }
        } else {
            let selected = ArchiveReaders.order.filter(config.sources.contains)
            ExportLog.info("starting archive run of \(selected.map(\.rawValue).joined(separator: ", ")) to \(root.path)")
            let cacheDirectory = cacheRoot.map { ArchiveIndex.cacheDirectory(for: ledger, in: $0) }
            // The "Health" section of `_index.md`, from the run log including this run's reads.
            archiver.health = { records, _ in Health.report(records, now: Date(), sources: config.sources, whatsAppRunning: Health.whatsAppRunning()).warnings }
            summary = try await archiver.run(ArchiveReaders.live(config, cursorFile: cacheDirectory?.appendingPathComponent("claudecode-cursors.json"),
                                                                 digestCache: cacheDirectory?.appendingPathComponent("ai-inbox-digests.json")), now: now)
            // After the run, so this run's reads count. The demo's clock is synthetic, so it gets no health check.
            let health = Health.report(try runLog.read().records, now: Date(), sources: config.sources, whatsAppRunning: Health.whatsAppRunning())
            for warning in health.warnings { stderr("Health: \(warning)") }
            if config.notify, let cacheDirectory {
                await Notifier.send(health.notices, sentFile: cacheDirectory.appendingPathComponent(SentNotices.fileName), now: Date())
            }
        }

        for line in summary.lines {
            let counts = line.counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            print("\(line.source.rawValue) (\(line.mode.rawValue)\(line.complete ? "" : ", incomplete")): \(counts.isEmpty ? "no changes" : counts.joined(separator: ", "))")
        }
        for line in summary.lines { for warning in line.warnings { stderr("Warning (\(line.source.rawValue)): \(warning)") } }
        print("Archive run complete: \(summary.added) added, \(summary.changed) changed, \(summary.tombstoned) tombstoned, \(summary.revoked) revoked, \(summary.pending) pending, \(summary.warnings.count) warnings.")
        print("Archive holds \(archiver.index.items.count) items. Pages: \(summary.pages.written) written, \(summary.pages.unchanged) unchanged, \(summary.pages.removed) removed. Output: \(root.path)")
        if let pageError = summary.pageError { stderr("Archive pages were not written: \(pageError) The ledger is up to date; run rebuild after fixing this.") }
        if !summary.failures.isEmpty {
            for (source, message) in summary.failures.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { stderr("Archive failed (\(source.rawValue)): \(message)") }
            stderr("Sources that did not archive: \(summary.failures.keys.map { $0.rawValue }.sorted().joined(separator: ", "))")
            exit(1)
        }
        if summary.pageError != nil { exit(1) }
    }

    @MainActor
    static func runRebuild(_ config: Config) throws {
        let root = config.output.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(Ledger.folderName).path) else {
            throw ExportError.message("No archive in \(root.path) (\(Ledger.folderName)/ is missing).")
        }
        let lock = try ArchiveLock(root.appendingPathComponent(ArchiveLock.name), owner: "archive run")
        defer { lock.release() }
        try Ledger.checkFolder(root)
        // Rebuild only reads the ledger, so it never needs this Mac's host id.
        let ledger = Ledger(root: root, host: "rebuild")
        let runLog = RunLog(root: root, host: "rebuild")
        let demo = try runLog.read().records.contains { $0.mode == ReadMode.demo.rawValue }
        let index = try ArchiveIndex.load(ledger, cacheRoot: demo ? nil : ArchiveIndex.defaultCacheRoot)
        for issue in index.issues { stderr("Warning: \(issue)") }
        let now = Date()
        // A demo archive has a synthetic clock, so it gets no health check (as in `archive --demo`).
        let health = demo ? [] : Health.warnings(runLog: runLog, now: now)
        let summary = try Archiver.rebuild(ledger, runLog: runLog, index: index, now: now, health: health, viewer: config.viewer)
        print("Rebuild complete: \(summary.written) pages written, \(summary.unchanged) unchanged, \(summary.removed) removed, from \(index.items.count) items.")
        print("Output: \(root.path)")
    }

    static func runVerify(_ config: Config) throws {
        let root = config.output.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else { throw ExportError.message("No archive at \(root.path).") }
        // Shares the archive lock, so a run in progress is not mistaken for torn lines.
        let lock = try ArchiveLock(root.appendingPathComponent(ArchiveLock.name), owner: "archive run or verify")
        defer { lock.release() }
        let report = try Verifier.verify(root: root, cacheRoot: ArchiveIndex.defaultCacheRoot)
        for note in report.notes { stderr("Note: \(note)") }
        for problem in report.problems { stderr("Problem: \(problem)") }
        print("Verified \(report.events) ledger events, \(report.runs) run log lines, \(report.items) items: \(report.problems.isEmpty ? "no problems" : "\(report.problems.count) problem\(report.problems.count == 1 ? "" : "s")").")
        if !report.problems.isEmpty { exit(1) }
    }

    /// Opens `_viewer/index.html` in the default browser. The viewer is plain files, so nothing keeps running.
    static func runOpen(_ config: Config) throws {
        let root = config.output.resolvingSymlinksInPath().standardizedFileURL
        let page = root.appendingPathComponent("_viewer/index.html")
        guard FileManager.default.fileExists(atPath: page.path) else {
            throw ExportError.message("No viewer in \(root.path). Run archive or rebuild without --no-viewer first.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [page.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportError.message("Could not open \(page.path).") }
        print("Opened \(page.path)")
    }

    static func read(_ source: ExportSource, window: (start: Date, end: Date, completedSince: Date), eventKit: EventKitExporter?, config: Config, now: Date) async throws -> ExportSnapshot {
        var snapshot = ExportSnapshot()
        switch source {
        case .notes:
            let result = try await NotesExporter.fetch()
            snapshot.notes = result.records
            snapshot.warnings[.notes] = result.warnings
        case .reminders:
            guard let eventKit else { throw ExportError.message("Reminders export is unavailable.") }
            let result = try await eventKit.reminders(completedSince: window.completedSince)
            snapshot.reminders = result.records
            snapshot.warnings[.reminders] = result.warnings
        case .calendar:
            guard let eventKit else { throw ExportError.message("Calendar export is unavailable.") }
            let result = try await eventKit.events(from: window.start, to: window.end)
            snapshot.events = result.records
            snapshot.warnings[.calendar] = result.warnings
        case .whatsapp:
            let result = try WhatsAppExporter.fetch(now: now, pastDays: config.pastDays, chatLimit: config.whatsappChats)
            snapshot.chats = result.records
            snapshot.warnings[.whatsapp] = result.warnings
        case .chatgpt, .claude, .claudecode, .instagram, .messenger:
            throw ExportError.message("\(source.displayName) is archive-only.")
        }
        return snapshot
    }

    static func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}
