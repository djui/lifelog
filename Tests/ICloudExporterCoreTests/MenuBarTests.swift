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
