import Foundation
import XCTest
@testable import LifelogCore

/// Ledger and run log lines as released versions wrote them must keep reading, and lines from a newer
/// Lifelog (another Mac on a later version) must be set apart from damage and stop page writes.
@MainActor
final class FormatVersionTests: XCTestCase {
    /// A demo archive written by format 1 (Lifelog 0.3). Add a `format-<n>` folder whenever the format changes; never edit one.
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// An archive folder holding a copy of a fixture's ledger and run log.
    func archive(format: Int) throws -> URL {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent(Ledger.folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["ledger", "runs"] {
            try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("format-\(format)/\(name)"), to: folder.appendingPathComponent(name))
        }
        return root
    }

    func appendRaw(_ line: String, to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func ledgerFile(_ root: URL, _ source: ArchiveSource) throws -> URL {
        let folder = root.appendingPathComponent("\(Ledger.folderName)/ledger/\(source.rawValue)")
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().last)
        return folder.appendingPathComponent(name)
    }

    func lines(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testFormatOneStillReads() throws {
        let root = try archive(format: 1)
        let ledger = Ledger(root: root, host: "mac1")
        let contents = try ledger.read()
        XCTAssertEqual(contents.issues, [])
        XCTAssertTrue(contents.newer.isEmpty)
        XCTAssertEqual(contents.events.count, 31)
        XCTAssertEqual(Set(contents.events.map(\.type)), [.added, .changed, .stateChanged, .rekeyed, .missingPending])

        let index = ArchiveIndex.fold(contents.events)
        XCTAssertEqual(index.issues, [])
        XCTAssertEqual(index.items.count, 14)
        XCTAssertEqual(Set(index.items.values.map(\.state)), [.active, .completed, .locked, .deleted, .expired, .revoked])

        let log = try RunLog(root: root, host: "mac1").read()
        XCTAssertEqual(log.records.count, 13)
        XCTAssertEqual(log.issues, [])
        XCTAssertTrue(log.newer.isEmpty)

        XCTAssertEqual(try Verifier.verify(root: root, cacheRoot: nil).problems, [])
        let summary = try Archiver.rebuild(ledger, runLog: RunLog(root: root, host: "mac1"), index: try ArchiveIndex.load(ledger, cacheRoot: nil), now: t0, viewer: false)
        XCTAssertGreaterThan(summary.written, 0)
    }

    func testNewerLinesAreSetApartFromDamage() throws {
        let root = try archive(format: 1)
        let file = try ledgerFile(root, .notes)
        let added = try XCTUnwrap(try lines(file).first)
        XCTAssertTrue(added.contains(#""kind":"note""#) && added.contains(#""v":1"#))
        try appendRaw(added.replacingOccurrences(of: #""v":1"#, with: #""v":2"#), to: file)
        try appendRaw(added.replacingOccurrences(of: #""kind":"note""#, with: #""kind":"sticker""#), to: file)
        try appendRaw(added.replacingOccurrences(of: #""type":"added""#, with: #""type":"merged""#), to: file)
        try appendRaw(#"{"at":"2026-11-04T10:00:00.000Z","key":{"id":"n","source":"notes"},"run":"r","state":"pinned","type":"stateChanged","v":1}"#, to: file)
        try appendRaw("not json", to: file)
        try appendRaw(#"{"v":1,"type":"added"}"#, to: file)
        let signal = root.appendingPathComponent("\(Ledger.folderName)/ledger/signal")
        try FileManager.default.createDirectory(at: signal, withIntermediateDirectories: true)
        try appendRaw(added, to: signal.appendingPathComponent("2026-11.mac2.jsonl"))

        let contents = try Ledger(root: root, host: "mac1").read()
        XCTAssertEqual(contents.events.count, 31, "the readable lines are all still there")
        XCTAssertEqual(contents.issues.count, 2, "damaged lines stay issues: \(contents.issues)")
        XCTAssertEqual(contents.newer.lines.map { $0.components(separatedBy: ": ").dropFirst().joined(separator: ": ") },
                       ["format 2", "item kind sticker", "event type merged", "state pinned", "source signal"])
        XCTAssertEqual(contents.newer.sources, ["notes", "signal"])
        XCTAssertEqual(try ArchiveIndex.load(Ledger(root: root, host: "mac1"), cacheRoot: nil).newer, contents.newer)

        let problems = try Verifier.verify(root: root, cacheRoot: nil).problems
        XCTAssertEqual(problems.filter { $0.contains("newer version of Lifelog") }.count, 5, "\(problems)")
    }

    func testNewerRunLogLinesAreSetApart() throws {
        let root = try archive(format: 1)
        let folder = root.appendingPathComponent("\(Ledger.folderName)/runs")
        let file = folder.appendingPathComponent(try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: folder.path).first))
        try appendRaw(try XCTUnwrap(try lines(file).last).replacingOccurrences(of: #""v":1"#, with: #""v":2"#), to: file)
        // A newer run log line that this version cannot decode at all.
        try appendRaw(#"{"v":3,"run":"r","source":"signal"}"#, to: file)
        let log = try RunLog(root: root, host: "mac1").read()
        XCTAssertEqual(log.records.count, 13)
        XCTAssertEqual(log.issues, [])
        XCTAssertEqual(log.newer.lines.count, 2)
        let ledger = Ledger(root: root, host: "mac1")
        XCTAssertThrowsError(try Archiver.rebuild(ledger, runLog: RunLog(root: root, host: "mac1"), index: try ArchiveIndex.load(ledger, cacheRoot: nil), now: t0, viewer: false))
    }

    func testNewerLinesStopTheirSourceAndThePagesUntilUpdated() async throws {
        let root = try temporaryDirectory()
        let cacheRoot = try temporaryDirectory()
        let options = ArchiveOptions(backfillSince: Date(timeIntervalSince1970: 946_684_800), rescanDays: 100, fullSweepDays: 7)
        func archiver() throws -> Archiver {
            let ledger = Ledger(root: root, host: "mac1")
            return Archiver(ledger: ledger, runLog: RunLog(root: root, host: "mac1"), index: try ArchiveIndex.load(ledger, cacheRoot: cacheRoot),
                            options: options, cacheRoot: cacheRoot, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        }
        let t0 = self.t0
        var reminders = ["1"]
        let readers: [ArchiveReader] = [
            FakeReader(.notes) { _ in
                [ArchiveRead(payloads: [.note(NoteRecord(id: "n1", title: "Note", account: "iCloud", folder: "Notes", created: t0, modified: t0, bodyHTML: "<p>n1</p>"))],
                             scope: .notes)]
            },
            FakeReader(.reminders) { _ in
                [ArchiveRead(payloads: reminders.map { .reminder(ReminderRecord(id: $0, title: "Buy milk \($0)", list: "Home", notes: nil, isCompleted: false, completionDate: nil,
                                                                                 due: nil, priority: 0, url: nil, externalID: "ext-\($0)")) },
                             scope: .reminders(completedSince: nil))]
            },
        ]
        var summary = try await archiver().run(readers, now: t0)
        XCTAssertNil(summary.pageError)

        // Another Mac on a newer Lifelog wrote a notes line this version does not understand.
        let notes = try ledgerFile(root, .notes)
        let newer = try XCTUnwrap(try lines(notes).last).replacingOccurrences(of: #""v":1"#, with: #""v":2"#)
        try appendRaw(newer, to: notes)
        reminders = ["1", "2"]
        summary = try await archiver().run(readers, now: t0 + 3600)
        XCTAssertEqual(Array(summary.failures.keys), [.notes])
        XCTAssertTrue(summary.failures[.notes]?.contains("newer version of Lifelog") == true)
        XCTAssertEqual(summary.added, 1, "other sources are still captured")
        XCTAssertTrue(summary.pageError?.contains("Update Lifelog") == true)
        let open = root.appendingPathComponent("Reminders/open.md")
        XCTAssertFalse(try String(contentsOf: open, encoding: .utf8).contains("Buy milk 2"), "no pages are written")
        let ledger = Ledger(root: root, host: "mac1")
        XCTAssertThrowsError(try Archiver.rebuild(ledger, runLog: RunLog(root: root, host: "mac1"), index: try ArchiveIndex.load(ledger, cacheRoot: nil), now: t0, viewer: false))

        // After the update the line reads (simulated by removing it), and the next run writes every page.
        let kept = try lines(notes).filter { $0 != newer }.map { $0 + "\n" }.joined()
        try Data(kept.utf8).write(to: notes)
        summary = try await archiver().run(readers, now: t0 + 7200)
        XCTAssertEqual(summary.failures, [:])
        XCTAssertNil(summary.pageError)
        XCTAssertEqual(summary.added + summary.changed, 0, "this run touches nothing")
        XCTAssertTrue(try String(contentsOf: open, encoding: .utf8).contains("Buy milk 2"), "the reminder added while blocked is on its page")
        let pending = ArchiveIndex.cacheDirectory(for: ledger, in: cacheRoot).appendingPathComponent(Archiver.pagesPendingName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }
}
