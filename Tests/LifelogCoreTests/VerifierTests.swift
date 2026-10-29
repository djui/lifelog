import XCTest
@testable import LifelogCore

/// Synthetic archives, corrupted on purpose.
final class VerifierTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_788_780_000.25)

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func note(_ id: String, _ body: String = "hello") -> ArchivedItem {
        let record = NoteRecord(id: id, title: "Title \(id)", account: "iCloud", folder: "Notes", created: now, modified: now, bodyHTML: "<p>\(body)</p>")
        return ArchivedItem(key: ItemKey(source: .notes, id: id), nativeID: id, partition: Partition(date: "2026-09-07", utcOffset: 7200),
                            stateSince: now, contentHash: MarkdownWriter.digest(Data(body.utf8)), payload: .note(record))
    }

    func added(_ item: ArchivedItem, run: String = "r1", offset: TimeInterval = 0) -> LedgerEvent {
        LedgerEvent(type: .added, at: now + offset, run: run, key: item.key, item: item)
    }

    /// A clean archive: two notes, one later deleted, and a run log line for the run.
    func archive() throws -> (root: URL, ledger: Ledger, file: URL) {
        let root = try temporaryDirectory()
        let ledger = Ledger(root: root, host: "mac1")
        try ledger.append([added(note("n1")), added(note("n2")),
                           LedgerEvent(type: .stateChanged, at: now + 1, run: "r1", key: note("n2").key, state: .deleted, reason: "missing")])
        try RunLog(root: root, host: "mac1").append([RunRecord(run: "r1", source: .notes, start: now, end: now + 2, complete: true, scope: "all notes")])
        return (root, ledger, root.appendingPathComponent(".archive/ledger/notes/\(JSONLines.month(now)).mac1.jsonl"))
    }

    func appendRaw(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func line(_ event: LedgerEvent) throws -> String { String(decoding: try JSONLines.encoder.encode(event), as: UTF8.self) + "\n" }

    func testCleanArchiveHasNoProblems() throws {
        let (root, _, _) = try archive()
        let report = try Verifier.verify(root: root, cacheRoot: nil)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.notes, [])
        XCTAssertEqual([report.events, report.runs, report.items], [3, 1, 2])
    }

    func testMissingLedgerIsAProblem() throws {
        XCTAssertEqual(try Verifier.verify(root: try temporaryDirectory(), cacheRoot: nil).problems.count, 1)
    }

    func testTornAndUnreadableLines() throws {
        let (root, _, file) = try archive()
        try appendRaw("not json\n{\"v\":1,\"type\":\"add", to: file)
        try appendRaw("{\"v\":1", to: RunLog(root: root, host: "mac1").directory.appendingPathComponent("\(JSONLines.month(now)).mac1.jsonl"))
        let problems = try Verifier.verify(root: root, cacheRoot: nil).problems
        XCTAssertEqual(problems.count, 3, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("unreadable line") })
        XCTAssertEqual(problems.filter { $0.contains("torn last line") }.count, 2)
    }

    func testDuplicateAndConflictingEvents() throws {
        let (root, _, file) = try archive()
        try appendRaw(try line(added(note("n1"))), to: file)
        try appendRaw(try line(added(note("n2", "other text"))), to: file)
        // Two changes of one key in one run are fine: a second export zip in the same run.
        try appendRaw(try line(LedgerEvent(type: .changed, at: now + 3, run: "r1", key: note("n1").key, item: note("n1", "a"))), to: file)
        try appendRaw(try line(LedgerEvent(type: .changed, at: now + 3, run: "r1", key: note("n1").key, item: note("n1", "b"))), to: file)
        let problems = try Verifier.verify(root: root, cacheRoot: nil).problems
        XCTAssertEqual(problems.count, 2, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("duplicate line at ledger/notes/") && $0.contains(":1, ") })
        XCTAssertTrue(problems.contains { $0.hasPrefix("conflicting added events for notes/n2 in run r1") })
    }

    func testEventsThatDoNotFold() throws {
        let (root, _, file) = try archive()
        try appendRaw(try line(LedgerEvent(type: .stateChanged, at: now + 5, run: "r1", key: ItemKey(source: .notes, id: "ghost"), state: .deleted)), to: file)
        try appendRaw(try line(LedgerEvent(type: .stateChanged, at: now + 5, run: "r1", key: note("n1").key)), to: file)
        var future = added(note("n3"))
        future.v = 2
        try appendRaw(try line(future), to: file)
        // A whatsapp event filed under notes.
        var stray = added(note("n4"))
        stray.key = ItemKey(source: .whatsapp, id: "jid/0/x")
        try appendRaw(try line(stray), to: file)
        let report = try Verifier.verify(root: root, cacheRoot: nil)
        XCTAssertEqual(report.problems.count, 4, "\(report.problems)")
        XCTAssertEqual(report.problems.filter { $0.hasPrefix("does not fold:") }.count, 2)
        XCTAssertTrue(report.problems.contains { $0.contains("unknown event version 2") })
        XCTAssertTrue(report.problems.contains { $0.contains("whatsapp event in the notes folder") })
    }

    func testRunsWithoutRunLogLineAreANote() throws {
        let (root, ledger, _) = try archive()
        try ledger.append([added(note("n5"), run: "r2", offset: 10)])
        let report = try Verifier.verify(root: root, cacheRoot: nil)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.notes.count, 1)
        XCTAssertTrue(report.notes[0].contains("r2"))
    }

    func testCacheMustMatchTheFold() throws {
        let (root, ledger, _) = try archive()
        let cacheRoot = try temporaryDirectory()
        var index = try ArchiveIndex.load(ledger, cacheRoot: cacheRoot)
        XCTAssertEqual(try Verifier.verify(root: root, cacheRoot: cacheRoot).problems, [])

        // A cache whose stamps still match the ledger but whose items do not.
        index.items[note("n1").key]?.state = .deleted
        index.save(ledger, cacheRoot: cacheRoot)
        let problems = try Verifier.verify(root: root, cacheRoot: cacheRoot).problems
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("disagrees with the ledger for 1 item(s) (notes/n1)"))

        // Once the ledger moves on, the cache is just stale.
        try ledger.append([added(note("n6"), offset: 20)])
        let report = try Verifier.verify(root: root, cacheRoot: cacheRoot)
        XCTAssertEqual(report.problems, [])
        XCTAssertTrue(report.notes.contains { $0.contains("older than the ledger") })
    }
}
