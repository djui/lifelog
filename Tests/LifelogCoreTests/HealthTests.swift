import XCTest
@testable import LifelogCore

/// Synthetic run logs only.
final class HealthTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let hour: TimeInterval = 3600
    let utc = TimeZone(identifier: "UTC")!

    func run(_ source: ArchiveSource = .whatsapp, at: Date, complete: Bool = true, warning: String? = nil, digest: String? = nil) -> RunRecord {
        RunRecord(run: "r-\(at.timeIntervalSince1970)", source: source, start: at - 5, end: at, complete: complete, scope: "test",
                  warnings: warning.map { [$0] } ?? [], mode: "rescan", digest: digest)
    }

    func report(_ records: [RunRecord], at now: Date, sources: Set<ArchiveSource>? = nil, running: Bool? = true) -> HealthReport {
        Health.report(records, now: now, sources: sources, whatsAppRunning: running, timeZone: utc)
    }

    func testRecentReadIsHealthy() {
        let health = report([run(at: t0)], at: t0 + 19 * hour)
        XCTAssertEqual(health.warnings, [])
        XCTAssertEqual(health.notices, [])
        XCTAssertEqual(health.hoursSinceWhatsApp ?? 0, 19, accuracy: 0.01)
    }

    func testEarlyWarningAt20Hours() {
        let health = report([run(at: t0), run(at: t0 + 10 * hour, complete: false)], at: t0 + 21 * hour)
        XCTAssertEqual(health.notices.map(\.kind), [.whatsappEarly])
        XCTAssertEqual(health.notices[0].id, "whatsapp-early-\(JSONLines.timestamp.string(from: t0))")
        XCTAssertEqual(health.warnings.count, 1)
        XCTAssertTrue(health.warnings[0].contains("21 h"), "an incomplete read does not reset the clock")
        XCTAssertTrue(health.warnings[0].contains(DateFormatter.utc(t0 + 24 * hour)))
        XCTAssertEqual(health.gaps, [])
    }

    func testLossWarningPast24HoursNamesTheWindow() {
        let now = t0 + 30 * hour
        let health = report([run(at: t0)], at: now, running: false)
        XCTAssertEqual(health.gaps, [CaptureGap(lastRead: t0, closed: nil, lossFrom: t0, lossUntil: t0 + 6 * hour)])
        XCTAssertEqual(health.notices.map(\.kind), [.whatsappLoss])
        let notice = health.notices[0]
        XCTAssertEqual(notice.id, "whatsapp-gap-\(JSONLines.timestamp.string(from: t0))")
        XCTAssertTrue(notice.body.contains("between \(DateFormatter.utc(t0)) and \(DateFormatter.utc(t0 + 6 * hour))"))
        XCTAssertTrue(notice.body.contains("WhatsApp Desktop is not running"))
        XCTAssertTrue(health.warnings.contains { $0.hasPrefix("WhatsApp Desktop is not running") })
    }

    func testClosedGapIsReportedWithTheSameID() {
        let open = report([run(at: t0)], at: t0 + 29 * hour)
        let records = [run(at: t0), run(at: t0 + 30 * hour)]
        let closed = report(records, at: t0 + 30 * hour + 60)
        XCTAssertEqual(closed.gaps, [CaptureGap(lastRead: t0, closed: t0 + 30 * hour, lossFrom: t0, lossUntil: t0 + 6 * hour)])
        XCTAssertEqual(closed.notices.map(\.id), open.notices.map(\.id))
        XCTAssertEqual(closed.warnings.count, 1)
        XCTAssertTrue(closed.warnings[0].contains("capture gap of 30 h"))

        // A day later the closed gap no longer notifies, but stays a warning for a month.
        let later = report(records + [run(at: t0 + 50 * hour)], at: t0 + 55 * hour)
        XCTAssertEqual(later.notices, [])
        XCTAssertEqual(later.warnings.count, 1)
        let twiceADay = (3...70).map { run(at: t0 + Double($0) * 12 * hour) }
        let aged = report(records + twiceADay, at: t0 + 35 * 24 * hour)
        XCTAssertEqual(aged.warnings, [])
        XCTAssertEqual(aged.gaps.count, 1)
    }

    func testOneNotificationPerGap() {
        // Hourly runs where WhatsApp fails from t0 + 1 h to t0 + 35 h, then recovers.
        var records = [run(at: t0)]
        var sent = SentNotices()
        var delivered: [HealthNotice.Kind] = []
        for step in 1...48 {
            let now = t0 + Double(step) * hour
            records.append(run(at: now, complete: step > 35, warning: "database locked"))
            for notice in sent.unsent(report(records, at: now, sources: [.whatsapp]).notices) {
                delivered.append(notice.kind)
                sent.mark(notice.id, at: now)
            }
        }
        // Read failures after three in a row, early at 20 h, loss at 25 h; closing the gap adds nothing.
        XCTAssertEqual(delivered, [.readFailures, .whatsappEarly, .whatsappLoss])
    }

    func testSentNoticesRoundtripAndExpire() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(SentNotices.fileName)
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(SentNotices.load(file), SentNotices())
        var sent = SentNotices()
        sent.mark("a", at: t0)
        try sent.save(file)
        XCTAssertEqual(SentNotices.load(file), sent)
        sent.mark("b", at: t0 + SentNotices.retention + 1)
        XCTAssertEqual(Set(sent.sent.keys), ["b"])
        let notice = HealthNotice(id: "b", kind: .whatsappLoss, title: "", body: "")
        XCTAssertEqual(sent.unsent([notice, HealthNotice(id: "c", kind: .whatsappEarly, title: "", body: ""), notice]).map(\.id), ["c"])
    }

    func testRepeatedFailuresPerSource() {
        let failing = (1...3).map { run(.calendar, at: t0 + Double($0) * hour, complete: false, warning: "access denied") }
        let health = report(failing, at: t0 + 4 * hour)
        XCTAssertEqual(health.notices.map(\.kind), [.readFailures])
        XCTAssertTrue(health.warnings[0].contains("Calendar: the last 3 reads failed or were partial (latest: access denied)"))
        XCTAssertEqual(report(Array(failing.dropFirst()), at: t0 + 4 * hour).warnings, [])
        XCTAssertEqual(report(failing + [run(.calendar, at: t0 + 4 * hour)], at: t0 + 5 * hour).warnings, [])
    }

    func testStaleAIImports() {
        let day: TimeInterval = 86_400
        let imported = run(.chatgpt, at: t0, digest: "abc")
        XCTAssertEqual(report([imported], at: t0 + 44 * day).warnings, [])
        let stale = report([imported], at: t0 + 46 * day)
        XCTAssertEqual(stale.notices.map(\.kind), [.staleImport])
        XCTAssertTrue(stale.warnings[0].contains("ChatGPT: no new export imported for 46 days"))
        // Never imported: counted from the first run of the archive, for the sources being archived.
        let never = report([run(.notes, at: t0)], at: t0 + 50 * day, sources: [.notes, .claude])
        XCTAssertEqual(never.warnings.count, 1)
        XCTAssertTrue(never.warnings[0].contains("Claude: no export imported in the 50 days since the archive started"))
        XCTAssertEqual(report([run(.notes, at: t0)], at: t0 + 50 * day).warnings, [], "not archived, not reported")
    }

    func testWarningsReadTheRunLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runLog = RunLog(root: root, host: "mac1")
        XCTAssertEqual(Health.warnings(runLog: runLog, now: t0, whatsAppRunning: nil), [])
        try runLog.append([run(at: t0)])
        XCTAssertEqual(Health.warnings(runLog: runLog, now: t0 + 30 * hour, whatsAppRunning: nil).count, 1)
    }
}

extension DateFormatter {
    static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
