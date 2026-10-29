import XCTest
@testable import LifelogCore

final class ExportTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_788_780_000)
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func doc(_ path: String, _ content: String = "example", source: ExportSource = .notes) -> ExportDocument {
        ExportDocument(path: path, content: content, source: source)
    }
    func testRejectsInvalidArguments() {
        for args in [["export"], ["export", "--output", "x", "--future-days", "0"], ["export", "--output", "x", "--sources", "notes,"], ["export", "--output", "x", "--demo", "--demo"]] {
            XCTAssertThrowsError(try Config(arguments: args))
        }
    }
    func testStableRerunsAndSelectedSourceCleanup() throws {
        let root = try temporaryDirectory()
        let store = ExportStore(output: root)
        let documents = [doc("Notes/first.md"), doc("Reminders/current-reminders.md", source: .reminders)]
        let first = try store.write(documents, sources: [.notes, .reminders], now: now, demo: true, warnings: [:])
        XCTAssertEqual(first.written, 3)
        let second = try store.write(documents, sources: [.notes, .reminders], now: now, demo: true, warnings: [:])
        XCTAssertEqual(second.written, 0)
        XCTAssertEqual(second.unchanged, 3)
        let third = try store.write([], sources: [.notes], now: now, demo: true, warnings: [:])
        XCTAssertEqual(third.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/first.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Reminders/current-reminders.md").path))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("_index.md")).contains("Reminders/current-reminders.md"))
    }
    func testEditedFileStopsBeforeOtherWrites() throws {
        let root = try temporaryDirectory(), store = ExportStore(output: root)
        _ = try store.write([doc("Notes/z.md")], sources: [.notes], now: now, demo: true, warnings: [:])
        try Data("user edit".utf8).write(to: root.appendingPathComponent("Notes/z.md"))
        XCTAssertThrowsError(try store.write([doc("Notes/a.md"), doc("Notes/z.md", "updated")], sources: [.notes], now: now, demo: true, warnings: [:]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/a.md").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/z.md")), "user edit")
    }
    func testUnmanagedFilesPreservedAndConflictRejected() throws {
        let root = try temporaryDirectory(), store = ExportStore(output: root)
        try Data("personal".utf8).write(to: root.appendingPathComponent("personal.txt"))
        try Data("user index".utf8).write(to: root.appendingPathComponent("_index.md"))
        XCTAssertThrowsError(try store.write([doc("Notes/a.md")], sources: [.notes], now: now, demo: true, warnings: [:]))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("personal.txt")), "personal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/a.md").path))
    }
    func testRejectsSymlinkAndTraversal() throws {
        let root = try temporaryDirectory(), outside = try temporaryDirectory(), store = ExportStore(output: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Notes"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.write([doc("Notes/a.md")], sources: [.notes], now: now, demo: true, warnings: [:]))
        XCTAssertThrowsError(try store.write([doc("Notes/../escape.md")], sources: [.notes], now: now, demo: true, warnings: [:]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testDemoCannotReplaceLive() throws {
        let store = ExportStore(output: try temporaryDirectory())
        _ = try store.write([doc("Notes/a.md")], sources: [.notes], now: now, demo: false, warnings: [:])
        XCTAssertThrowsError(try store.write([], sources: [.notes], now: now, demo: true, warnings: [:]))
    }
    func testNoteCollisionsAndRenameCleanup() throws {
        let root = try temporaryDirectory(), store = ExportStore(output: root)
        let config = try Config(arguments: ["export", "--output", root.path, "--sources", "notes"])
        var snapshot = ExportSnapshot()
        snapshot.notes = ["a", "b"].map { NoteRecord(id: $0, title: "../Same / title", account: "Cloud", folder: "Travel", created: nil, modified: nil, bodyHTML: "<p>Hello</p>") }
        let first = try MarkdownWriter.documents(snapshot: snapshot, config: config, now: now)
        XCTAssertEqual(Set(first.map(\.path)).count, 2)
        XCTAssertTrue(first.allSatisfy { !$0.path.contains("../") })
        _ = try store.write(first, sources: [.notes], now: now, demo: true, warnings: [:])
        snapshot.notes[0].title = "Renamed"
        let next = try MarkdownWriter.documents(snapshot: snapshot, config: config, now: now)
        let summary = try store.write(next, sources: [.notes], now: now, demo: true, warnings: [:])
        XCTAssertEqual(summary.removed, 1)
    }
    func testAllDayDatesAndOngoingEvents() throws {
        let config = try Config(arguments: ["export", "--output", "/tmp/unused", "--sources", "calendar"])
        var snapshot = ExportSnapshot()
        snapshot.events = [CalendarRecord(id: "one", title: "Holiday", calendar: "Personal", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600), isAllDay: true, timeZone: "Europe/Stockholm", location: nil, notes: nil, url: nil, startDate: "2026-09-07", endDate: "2026-09-08")]
        let docs = try MarkdownWriter.documents(snapshot: snapshot, config: config, now: now)
        XCTAssertEqual(docs.count, 2)
        XCTAssertTrue(docs.allSatisfy { $0.content.contains("Start date: 2026-09-07") && $0.content.contains("2026-09-08 (exclusive)") })
    }

    func testCaseOnlyRenamesAndEmptyFallbackStayStable() {
        XCTAssertEqual(MarkdownWriter.safeComponent("Travel"), MarkdownWriter.safeComponent("TRAVEL"))
        XCTAssertEqual(MarkdownWriter.safeComponent(""), MarkdownWriter.safeComponent("Untitled"))
    }

    func testSubsetExportPreservesOtherSourceWarnings() throws {
        let root = try temporaryDirectory(), store = ExportStore(output: root)
        _ = try store.write([], sources: [.notes], now: now, demo: true, warnings: [.notes: ["2 protected notes skipped."]])
        _ = try store.write([], sources: [.reminders], now: now, demo: true, warnings: [:])
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("_index.md")).contains("2 protected notes skipped."))
        _ = try store.write([], sources: [.notes], now: now, demo: true, warnings: [:])
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("_index.md")).contains("2 protected notes skipped."))
    }

    func testInterruptedWriteRecoversDuringLaterSource() throws {
        let root = try temporaryDirectory(), store = ExportStore(output: root)
        _ = try store.write([doc("Notes/a.md", "old")], sources: [.notes], now: now, demo: true, warnings: [:])
        let before = try manifest(at: root)
        var after = before
        after.files["Notes/a.md"]?.digest = MarkdownWriter.digest(Data("new".utf8))
        after.files["Notes/b.md"] = ExportStore.Entry(source: "notes", digest: MarkdownWriter.digest(Data("added".utf8)))
        try journal(ExportStore.Pending(committed: before, before: before, after: after, sources: ["notes"]), at: root)
        try Data("new".utf8).write(to: root.appendingPathComponent("Notes/a.md"))
        _ = try store.write([doc("Reminders/current-reminders.md", source: .reminders)], sources: [.reminders], now: now, demo: true, warnings: [:])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/a.md")), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Reminders/current-reminders.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ExportStore.pendingName).path))
        _ = try store.write([doc("Notes/a.md", "latest"), doc("Notes/b.md", "added")], sources: [.notes], now: now, demo: true, warnings: [:])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/a.md")), "latest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ExportStore.pendingName).path))
    }

    func testEachSourceWriteAppearsWithoutWaitingForOthers() throws {
        let root = try temporaryDirectory(), store = ExportStore(output: root)
        _ = try store.write([doc("Notes/a.md")], sources: [.notes], now: now, demo: true, warnings: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/a.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Reminders/current-reminders.md").path))
        _ = try store.write([doc("Reminders/current-reminders.md", source: .reminders)], sources: [.reminders], now: now, demo: true, warnings: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/a.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Reminders/current-reminders.md").path))
    }

    func testRecoveryAfterRepeatedInterruptionAndProtectsUserEdits() throws {
        let root = try temporaryDirectory(), store = ExportStore(output: root)
        _ = try store.write([doc("Notes/a.md", "old")], sources: [.notes], now: now, demo: true, warnings: [:])
        let committed = try manifest(at: root)
        var before = committed, after = committed
        before.files["Notes/a.md"]?.digest = MarkdownWriter.digest(Data("intermediate".utf8))
        after.files["Notes/a.md"]?.digest = MarkdownWriter.digest(Data("new".utf8))
        try journal(ExportStore.Pending(committed: committed, before: before, after: after, sources: ["notes"]), at: root)
        try Data("manual edit".utf8).write(to: root.appendingPathComponent("Notes/a.md"))
        XCTAssertThrowsError(try store.write([doc("Notes/a.md", "latest")], sources: [.notes], now: now, demo: true, warnings: [:]))
        try Data("intermediate".utf8).write(to: root.appendingPathComponent("Notes/a.md"))
        _ = try store.write([doc("Notes/a.md", "latest")], sources: [.notes], now: now, demo: true, warnings: [:])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/a.md")), "latest")
    }

    func manifest(at root: URL) throws -> ExportStore.Manifest {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExportStore.Manifest.self, from: Data(contentsOf: root.appendingPathComponent(ExportStore.manifestName)))
    }

    func journal(_ pending: ExportStore.Pending, at root: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(pending).write(to: root.appendingPathComponent(ExportStore.pendingName))
    }
}
