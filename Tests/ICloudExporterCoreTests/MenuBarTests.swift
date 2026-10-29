import AppKit
import XCTest
@testable import ICloudExporterCore

final class MenuBarTests: XCTestCase {
    func testLaunchModeKeepsTheCLIForArgumentsAndTerminals() {
        XCTAssertEqual(LaunchMode.decide([], isTerminal: false, isAppBundle: true), .menuBar, "opened from Finder or at login")
        XCTAssertEqual(LaunchMode.decide(["-psn_0_12345"], isTerminal: false, isAppBundle: true), .menuBar, "older Launch Services argument")
        XCTAssertEqual(LaunchMode.decide(["app"], isTerminal: true, isAppBundle: false), .menuBar)
        XCTAssertEqual(LaunchMode.decide([], isTerminal: true, isAppBundle: true), .cli([]), "typed in Terminal: help")
        XCTAssertEqual(LaunchMode.decide([], isTerminal: false, isAppBundle: false), .cli([]), "swift run or a bare binary")
        XCTAssertEqual(LaunchMode.decide(["archive", "--output", "/tmp/a"], isTerminal: false, isAppBundle: true), .cli(["archive", "--output", "/tmp/a"]),
                       "launchd runs keep working")
        XCTAssertEqual(LaunchMode.decide(["app", "--output", "/tmp/a"], isTerminal: false, isAppBundle: true), .cli(["app", "--output", "/tmp/a"]))
    }

    func testMenuBarIconIsATemplateWithInk() throws {
        let image = MenuBarIcon.image()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<36 { for y in 0..<36 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
        XCTAssertGreaterThan(inked, 60, "the glyph draws its outline")
        XCTAssertLessThan(inked, 36 * 36 / 2, "an outline, not a filled square")
    }
}

final class ScheduleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let lanes = Lane.all

    func record(_ source: ArchiveSource, _ start: Date, complete: Bool = true) -> RunRecord {
        RunRecord(run: "r", source: source, start: start, end: start + 5, complete: complete, scope: "test")
    }

    func testEveryLaneIsDueOnAFreshArchive() {
        XCTAssertEqual(Schedule.due(lanes, now: t0, last: [:]).map(\.id), ["frequent", "hourly"])
        XCTAssertNil(Schedule.next(lanes, now: t0, last: [:]))
    }

    func testLastRunCountsFailedReadsAndAppAttempts() {
        let records = [record(.whatsapp, t0, complete: false), record(.notes, t0 - 100), record(.calendar, t0 - 50)]
        XCTAssertEqual(Schedule.lastRun(.frequent, records: records), t0, "a failed read is still a run, so a failing source is not retried every minute")
        XCTAssertEqual(Schedule.lastRun(.hourly, records: records), t0 - 100)
        XCTAssertEqual(Schedule.lastRun(.hourly, records: records, attempted: t0 + 10), t0 + 10)
        XCTAssertNil(Schedule.lastRun(.hourly, records: [record(.whatsapp, t0)]))
    }

    func testLanesComeDueOnTheirOwnIntervalsWithSlack() {
        let last = ["frequent": t0, "hourly": t0]
        XCTAssertEqual(Schedule.due(lanes, now: t0 + 60, last: last), [])
        XCTAssertEqual(Schedule.next(lanes, now: t0 + 60, last: last), t0 + 600)
        // The minute tick lands 20 s early: close enough.
        XCTAssertEqual(Schedule.due(lanes, now: t0 + 580, last: last).map(\.id), ["frequent"])
        XCTAssertEqual(Schedule.due(lanes, now: t0 + 3600, last: ["frequent": t0 + 3300, "hourly": t0]).map(\.id), ["hourly"])
    }

    func testWakingAfterSleepRunsWhatIsOverdue() {
        // Asleep for 5 hours: both lanes are due at once on wake, once each.
        XCTAssertEqual(Schedule.due(lanes, now: t0 + 5 * 3600, last: ["frequent": t0, "hourly": t0]).map(\.id), ["frequent", "hourly"])
    }

    func testPauseHoldsEveryLaneUntilItEnds() {
        let last = ["frequent": t0, "hourly": t0]
        XCTAssertEqual(Schedule.due(lanes, now: t0 + 4000, last: last, pausedUntil: t0 + 7200), [])
        XCTAssertEqual(Schedule.next(lanes, now: t0 + 4000, last: last, pausedUntil: t0 + 7200), t0 + 7200)
        XCTAssertEqual(Schedule.due(lanes, now: t0 + 7200, last: last, pausedUntil: t0 + 7200).map(\.id), ["frequent", "hourly"])
    }

    func testLaneArgumentsAreACLIArchiveRun() throws {
        let arguments = Lane.frequent.arguments(output: URL(fileURLWithPath: "/tmp/Archive"))
        XCTAssertEqual(arguments, ["archive", "--output", "/tmp/Archive", "--sources", "reminders,calendar,whatsapp,claudecode"])
        XCTAssertEqual(try Config(arguments: arguments).sources, [.reminders, .calendar, .whatsapp, .claudecode])
        XCTAssertEqual(Set(Lane.all.flatMap(\.sources)), Set(ArchiveSource.allCases), "every source has a lane")
    }

    func testOnlyArchiveAgentsHandOverScheduling() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("com.djui.icloud-exporter.plist"))
        XCTAssertEqual(LaunchAgents.archiveAgents(in: folder), [])
        try Data().write(to: folder.appendingPathComponent("com.djui.icloud-exporter.archive-slow.plist"))
        XCTAssertEqual(LaunchAgents.archiveAgents(in: folder), ["com.djui.icloud-exporter.archive-slow.plist"])
    }
}

final class MenuStatusTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func record(_ source: ArchiveSource, _ end: Date, complete: Bool = true, warning: String? = nil) -> RunRecord {
        RunRecord(run: "r", source: source, start: end - 5, end: end, complete: complete, scope: "test", warnings: warning.map { [$0] } ?? [])
    }

    func status(_ records: [RunRecord], running: Lane? = nil, reading: ArchiveSource? = nil, paused: Date? = nil, failure: String? = nil,
                health: [String] = []) -> MenuStatus {
        MenuStatus.make(records: records, now: t0, running: running, reading: reading, pausedUntil: paused, failure: failure, health: health) {
            "t+\(Int($0.timeIntervalSince(self.t0)))"
        }
    }

    func testRowsShowEachSourcesNewestRead() {
        let records = [record(.whatsapp, t0 - 600, complete: false, warning: "WhatsApp data could not be read."), record(.whatsapp, t0 - 1200),
                       record(.notes, t0 - 60), record(.reminders, t0 - 30)]
        let menu = status(records)
        XCTAssertEqual(menu.sources.map(\.source), [.reminders, .whatsapp, .notes], "in reading order, only sources that ran")
        XCTAssertEqual(menu.sources[0], SourceStatus(source: .reminders, state: .ok, detail: "t+-30"))
        XCTAssertEqual(menu.sources[1], SourceStatus(source: .whatsapp, state: .failed, detail: "t+-600: WhatsApp data could not be read."))
        XCTAssertEqual(menu.icon, .attention, "a failing source needs attention")
    }

    func testIconPicksTheMostUrgentState() {
        let ok = [record(.reminders, t0 - 30)]
        XCTAssertEqual(status(ok).icon, .idle)
        XCTAssertEqual(status(ok, health: ["No complete WhatsApp read for 21 h."]).icon, .attention)
        XCTAssertEqual(status(ok, failure: "The run took too long and was stopped.", health: ["x"]).icon, .failed)
        XCTAssertEqual(status(ok, paused: t0 + 60, failure: "x").icon, .paused)
        XCTAssertEqual(status(ok, paused: t0 - 60).icon, .idle, "a pause that ended")
        XCTAssertEqual(status(ok, running: .frequent, paused: t0 + 60).icon, .running, "Run Now while paused")
    }

    func testReadingSourceAndFailureAreShown() {
        let menu = status([record(.reminders, t0 - 30)], running: .frequent, reading: .whatsapp, failure: "Could not start", health: ["Health"])
        XCTAssertEqual(menu.sources.last, SourceStatus(source: .whatsapp, state: .reading, detail: "reading…"))
        XCTAssertEqual(menu.warnings, ["Last run failed: Could not start", "Health"])
    }

    func testProgressLinesRoundTripAndIgnoreOtherOutput() throws {
        let step = ArchiveProgress(.reading, .whatsapp)
        XCTAssertEqual(step.line, #"{"progress":"reading","source":"whatsapp"}"#)
        XCTAssertEqual(ArchiveProgress.parse(step.line), step)
        XCTAssertEqual(ArchiveProgress.parse(#"{"progress":"pages"}"#), ArchiveProgress(.pages))
        XCTAssertNil(ArchiveProgress.parse("whatsapp (rescan): 2 added"))
        XCTAssertNil(ArchiveProgress.parse(#"{"progress":"unknown"}"#))
        XCTAssertTrue(try Config(arguments: ["archive", "--output", "/tmp/a", "--progress"]).progress)
        XCTAssertThrowsError(try Config(arguments: ["rebuild", "--output", "/tmp/a", "--progress"]))
    }

    func testEveryIconStateLooksDifferent() throws {
        var seen: [String: IconState] = [:]
        for state in IconState.allCases {
            let image = MenuBarIcon.image(state)
            XCTAssertTrue(image.isTemplate)
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            let signature = (0..<36).flatMap { y in (0..<36).map { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 ? "1" : "0" } }.joined()
            XCTAssertNil(seen[signature], "\(state) looks like \(seen[signature].map(\.rawValue) ?? "")")
            seen[signature] = state
            if let folder = ProcessInfo.processInfo.environment["ICON_PREVIEW_DIR"] {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(state.rawValue).png"))
            }
        }
    }
}

final class AppSettingsTests: XCTestCase {
    func defaults() -> UserDefaults {
        let name = "icloud-exporter-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testDefaultsMatchTheCLIAndTheTwoLaunchdAgents() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.lanes, Lane.all)
        let output = URL(fileURLWithPath: "/tmp/Archive")
        let config = try Config(arguments: settings.arguments(for: .frequent, output: output))
        let cli = try Config(arguments: ["archive", "--output", "/tmp/Archive"])
        XCTAssertEqual([config.backfillSince, config.rescanDays, config.fullSweepDays, config.viewer, config.aiInbox] as [AnyHashable],
                       [cli.backfillSince, cli.rescanDays, cli.fullSweepDays, cli.viewer, cli.aiInbox] as [AnyHashable], "defaults add no options")
        XCTAssertTrue(config.progress)
    }

    func testEveryArchiveOptionReachesTheCLI() throws {
        var settings = AppSettings()
        settings.aiInbox = URL(fileURLWithPath: "/tmp/Exports", isDirectory: true)
        settings.backfillSince = "2015-06-01"
        settings.rescanDays = 30
        settings.fullSweepDays = 14
        settings.viewer = false
        settings.frequentMinutes = 15
        settings.sourceLanes = [.notes: Lane.frequent.id, .whatsapp: AppSettings.off]
        let frequent = try XCTUnwrap(settings.lanes.first)
        XCTAssertEqual(frequent.interval, 900)
        XCTAssertEqual(frequent.sources, [.reminders, .calendar, .claudecode, .notes])
        let config = try Config(arguments: settings.arguments(for: frequent, output: URL(fileURLWithPath: "/tmp/Archive")))
        XCTAssertEqual(config.sources, [.reminders, .calendar, .claudecode, .notes])
        XCTAssertEqual(config.aiInbox.path, "/tmp/Exports")
        XCTAssertEqual(config.backfillSince, Config.civilDate("2015-06-01"))
        XCTAssertEqual([config.rescanDays, config.fullSweepDays], [30, 14])
        XCTAssertFalse(config.viewer)
        XCTAssertFalse(settings.lanes.flatMap(\.sources).contains(.whatsapp), "a source that is off is in no lane")
    }

    func testALaneWithoutSourcesIsLeftOut() {
        var settings = AppSettings()
        for source in Lane.hourly.sources { settings.sourceLanes[source] = AppSettings.off }
        XCTAssertEqual(settings.lanes.map(\.id), ["frequent"])
    }

    func testSettingsRoundTripAndIgnoreInvalidValues() {
        let store = defaults()
        var settings = AppSettings()
        settings.notify = false
        settings.runOnWake = false
        settings.deferOnBattery = true
        settings.hourlyMinutes = 120
        settings.sourceLanes = [.claude: AppSettings.off]
        settings.backfillSince = "2010-01-01"
        settings.save(store)
        XCTAssertEqual(AppSettings.load(store), settings)

        store.set(0, forKey: "rescanDays")
        store.set("yesterday", forKey: "backfillSince")
        store.set(["claude": "weekly", "nope": "hourly"], forKey: "sourceLanes")
        let loaded = AppSettings.load(store)
        XCTAssertEqual(loaded.rescanDays, 100)
        XCTAssertNil(loaded.backfillSince)
        XCTAssertEqual(loaded.sourceLanes, [:])
    }
}
