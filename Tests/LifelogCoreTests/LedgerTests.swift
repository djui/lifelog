import XCTest
@testable import LifelogCore

final class LedgerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_788_780_000.25)

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func note(_ id: String, _ body: String = "hello", at: Date? = nil) -> ArchivedItem {
        let record = NoteRecord(id: id, title: "Title \(id)", account: "iCloud", folder: "Notes", created: now, modified: now, bodyHTML: "<p>\(body)</p>")
        return ArchivedItem(key: ItemKey(source: .notes, id: id), nativeID: id, partition: Partition(date: "2026-09-07", utcOffset: 7200),
                            stateSince: at ?? now, contentHash: MarkdownWriter.digest(Data(body.utf8)), payload: .note(record))
    }

    func message(_ id: String, at: Date) -> ArchivedItem {
        let record = WhatsAppMessageRecord(id: id, sender: "Anna", timestamp: at, fromMe: false, text: "see you at 8 / ünïcode \"quoted\"\nline", placeholder: nil)
        return ArchivedItem(key: ItemKey(source: .whatsapp, id: "jid/0/\(id)"), nativeID: id, partition: Partition(date: "2026-09-07", utcOffset: 0),
                            stateSince: at, contentHash: "h\(id)",
                            payload: .message(WhatsAppArchiveMessage(chatJID: "123@s.whatsapp.net", chatTitle: "Anna", chatKind: "direct", message: record)))
    }

    func added(_ item: ArchivedItem, at: Date, run: String = "r1") -> LedgerEvent {
        LedgerEvent(type: .added, at: at, run: run, key: item.key, item: item)
    }

    func testAppendReadRoundtrip() throws {
        let root = try temporaryDirectory()
        let ledger = Ledger(root: root, host: "mac1")
        let reminder = ArchivedItem(key: ItemKey(source: .reminders, id: "ext-1"), nativeID: "local-1", partition: Partition(date: "2026-09-01", utcOffset: 3600),
                                    state: .completed, stateSince: now, flags: ItemFlags(edited: true), contentHash: "abc",
                                    payload: .reminder(ReminderRecord(id: "local-1", title: "Buy milk", list: "Home", notes: nil, isCompleted: true, completionDate: now, due: "2026-09-01", priority: 0, url: nil)))
        let event = ArchivedItem(key: ItemKey(source: .calendar, id: "ext-2@2026-09-07"), nativeID: "cal-2", partition: Partition(date: "2026-09-07", utcOffset: 7200),
                                 stateSince: now, flags: ItemFlags(rescheduledFrom: "2026-09-06T08:30:00+02:00"), contentHash: "def",
                                 payload: .event(CalendarRecord(id: "cal-2", title: "Dentist", calendar: "Home", start: now, end: now + 3600, isAllDay: false, timeZone: "Europe/Berlin", location: nil, notes: nil, url: nil)))
        let events = [
            added(note("n1"), at: now), added(reminder, at: now), added(event, at: now), added(message("m1", at: now), at: now),
            LedgerEvent(type: .stateChanged, at: now + 60, run: "r2", key: event.key, state: .deleted, reason: "gone after two complete reads"),
            LedgerEvent(type: .rekeyed, at: now + 60, run: "r2", key: ItemKey(source: .notes, id: "n1"), newKey: ItemKey(source: .notes, id: "n1b")),
        ]
        try ledger.append(events)
        let contents = try ledger.read()
        XCTAssertEqual(contents.issues, [])
        // Order is kept within a source; equal timestamps across sources are grouped by source.
        for source in ArchiveSource.allCases {
            XCTAssertEqual(contents.events.filter { $0.key.source == source }, events.filter { $0.key.source == source })
        }
        XCTAssertEqual(contents.events.count, events.count)

        let month = JSONLines.month(now)
        let file = root.appendingPathComponent(".archive/ledger/notes/\(month).mac1.jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("\"kind\":\"note\""))
        XCTAssertTrue(text.contains(".250Z\""), "dates keep sub-second precision")
        XCTAssertFalse(text.contains("\\/"))
        // Appending never rewrites earlier lines.
        try ledger.append([added(note("n2"), at: now + 120)])
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix(text))
    }

    func testTornLastLineIsIgnoredAndCutBeforeNextAppend() throws {
        let root = try temporaryDirectory()
        let ledger = Ledger(root: root, host: "mac1")
        try ledger.append([added(note("n1"), at: now)])
        let file = root.appendingPathComponent(".archive/ledger/notes/\(JSONLines.month(now)).mac1.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"type\":\"add".utf8))
        try handle.close()

        var contents = try ledger.read()
        XCTAssertEqual(contents.events.map(\.key.id), ["n1"])
        XCTAssertEqual(contents.issues.count, 1)
        XCTAssertTrue(contents.issues[0].contains("torn last line"))

        try ledger.append([added(note("n2"), at: now + 1)])
        contents = try ledger.read()
        XCTAssertEqual(contents.events.map(\.key.id), ["n1", "n2"])
        XCTAssertEqual(contents.issues, [])
    }

    func testCorruptLinesAndForeignFilesAreReportedNotFatal() throws {
        let root = try temporaryDirectory()
        let ledger = Ledger(root: root, host: "mac1")
        try ledger.append([added(note("n1"), at: now)])
        let folder = root.appendingPathComponent(".archive/ledger/notes")
        let file = folder.appendingPathComponent("\(JSONLines.month(now)).mac1.jsonl")
        var data = try Data(contentsOf: file)
        data.append(Data("not json\n".utf8))
        try data.write(to: file)
        try Data("x".utf8).write(to: folder.appendingPathComponent("2026-09.mac1 (1).jsonl"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".archive/ledger/myspace"), withIntermediateDirectories: true)

        let contents = try ledger.read()
        XCTAssertEqual(contents.events.map(\.key.id), ["n1"])
        XCTAssertEqual(contents.issues.count, 3)
    }

    func testTwoHostsInterleaveInTimestampOrder() throws {
        let root = try temporaryDirectory()
        let a = Ledger(root: root, host: "mac1"), b = Ledger(root: root, host: "mac2")
        try a.append([added(message("1", at: now), at: now), added(message("3", at: now + 20), at: now + 20)])
        try b.append([added(message("2", at: now + 10), at: now + 10), added(message("4", at: now + 30), at: now + 30)])
        // A later month on one host still sorts by time, not by file.
        let later = now + 40 * 86_400
        try b.append([added(message("6", at: later), at: later)])
        try a.append([added(message("5", at: now + 40), at: now + 40)])

        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".archive/ledger/whatsapp").path).sorted()
        XCTAssertEqual(files, ["\(JSONLines.month(now)).mac1.jsonl", "\(JSONLines.month(now)).mac2.jsonl", "\(JSONLines.month(later)).mac2.jsonl"])
        XCTAssertEqual(try a.read().events.map(\.item!.nativeID), ["1", "2", "3", "4", "5", "6"])
        // Same timestamp on two hosts: host order breaks the tie identically on every Mac.
        try b.append([added(message("7b", at: later + 1), at: later + 1)])
        try a.append([added(message("7a", at: later + 1), at: later + 1)])
        XCTAssertEqual(try b.read().events.suffix(2).map(\.item!.nativeID), ["7a", "7b"])
    }

    func testFoldAppliesLifecycleAndIsIdempotent() throws {
        let n1 = note("n1"), n2 = note("n2")
        var edited = note("n1", "edited", at: now + 10)
        edited.flags.edited = true
        let events = [
            added(n1, at: now), added(n2, at: now),
            LedgerEvent(type: .changed, at: now + 10, run: "r2", key: n1.key, item: edited),
            LedgerEvent(type: .missingPending, at: now + 20, run: "r3", key: n2.key),
            LedgerEvent(type: .stateChanged, at: now + 30, run: "r4", key: n2.key, state: .deleted, reason: "gone"),
            LedgerEvent(type: .rekeyed, at: now + 40, run: "r5", key: n1.key, newKey: ItemKey(source: .notes, id: "n1-new")),
        ]
        let index = ArchiveIndex.fold(events)
        XCTAssertEqual(index.issues, [])
        XCTAssertEqual(index.items.keys.map(\.id).sorted(), ["n1-new", "n2"])
        let moved = try XCTUnwrap(index.items[ItemKey(source: .notes, id: "n1-new")])
        XCTAssertEqual(moved.contentHash, edited.contentHash)
        XCTAssertTrue(moved.flags.edited)
        XCTAssertEqual(moved.firstSeen, now)
        XCTAssertEqual(moved.lastSeen, now + 10)
        let gone = try XCTUnwrap(index.items[n2.key])
        XCTAssertEqual(gone.state, .deleted)
        XCTAssertEqual(gone.stateSince, now + 30)
        XCTAssertEqual(gone.reason, "gone")
        XCTAssertNil(gone.missingSince)
        XCTAssertEqual(gone.payload, n2.payload, "a tombstone keeps the last seen content")

        // Every event delivered twice (e.g. a re-synced file) folds to the same index.
        XCTAssertEqual(ArchiveIndex.fold(events.flatMap { [$0, $0] }), index)
        XCTAssertEqual(ArchiveIndex.fold(events), index)
    }

    func testFoldReportsEventsForUnknownItems() {
        let index = ArchiveIndex.fold([LedgerEvent(type: .stateChanged, at: now, run: "r1", key: ItemKey(source: .notes, id: "x"), state: .deleted)])
        XCTAssertTrue(index.items.isEmpty)
        XCTAssertEqual(index.issues.count, 1)
    }

    func testIndexCacheLivesOutsideArchiveAndFollowsLedger() throws {
        let root = try temporaryDirectory(), cache = try temporaryDirectory()
        let ledger = Ledger(root: root, host: "mac1")
        try ledger.append([added(note("n1"), at: now)])
        XCTAssertEqual(try ArchiveIndex.load(ledger, cacheRoot: cache).items.count, 1)
        let cached = try FileManager.default.subpathsOfDirectory(atPath: cache.path).filter { $0.hasSuffix("index.json") }
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent(".archive").path).sorted(),
                       ["ledger", "ledger/notes", "ledger/notes/\(JSONLines.month(now)).mac1.jsonl"])

        XCTAssertEqual(try ArchiveIndex.load(ledger, cacheRoot: cache), ArchiveIndex.fold(try ledger.read().events))
        try ledger.append([added(note("n2"), at: now + 1)])
        XCTAssertEqual(try ArchiveIndex.load(ledger, cacheRoot: cache).items.count, 2)
    }

    func testRunLogRoundtripAndLastComplete() throws {
        let root = try temporaryDirectory()
        let log = RunLog(root: root, host: "mac1")
        let ok = RunRecord(run: "r1", source: .whatsapp, start: now, end: now + 5, complete: true, scope: "rescan 100 days", counts: ["added": 3], warnings: [])
        let partial = RunRecord(run: "r2", source: .whatsapp, start: now + 600, end: now + 605, complete: false, scope: "rescan 100 days", warnings: ["database locked"])
        try log.append([ok, partial])
        let read = try log.read()
        XCTAssertEqual(read.records, [ok, partial])
        XCTAssertEqual(read.issues, [])
        XCTAssertEqual(RunLog.lastComplete(read.records)[.whatsapp], ok)
    }

    func testHostIDIsCreatedOnceAndValidated() throws {
        let directory = try temporaryDirectory()
        let first = try HostID.current(directory: directory)
        XCTAssertTrue(HostID.valid(first))
        XCTAssertEqual(try HostID.current(directory: directory), first)
        XCTAssertFalse(HostID.valid("Mac.1"))
        XCTAssertNil(JSONLines.parse("2026-10.Mac.jsonl"))
        XCTAssertNotNil(JSONLines.parse("2026-10.mac1.jsonl"))
    }

    func testLockIsExclusive() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent(ArchiveLock.name)
        let lock = try ArchiveLock(url, owner: "archive run")
        XCTAssertThrowsError(try ArchiveLock(url, owner: "export")) { XCTAssertEqual($0.localizedDescription, "Another export is using this output directory.") }
        lock.release()
        XCTAssertNoThrow(try ArchiveLock(url, owner: "export"))
    }

    func testExportAndArchiveFoldersDoNotMix() throws {
        let export = try temporaryDirectory()
        _ = try ExportStore(output: export).write([ExportDocument(path: "Notes/a.md", content: "a", source: .notes)], sources: [.notes], now: now, demo: true, warnings: [:])
        XCTAssertThrowsError(try Ledger.checkFolder(export))

        let archive = try temporaryDirectory()
        XCTAssertNoThrow(try Ledger.checkFolder(archive))
        try Ledger(root: archive, host: "mac1").append([added(note("n1"), at: now)])
        XCTAssertThrowsError(try ExportStore(output: archive).write([], sources: [.notes], now: now, demo: true, warnings: [:]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent(ExportStore.manifestName).path))
    }
}

final class ConfigTests: XCTestCase {
    func testExportDefaultsUnchanged() throws {
        let config = try Config(arguments: ["export", "--output", "/tmp/x"])
        XCTAssertEqual(config.command, .export)
        XCTAssertEqual(config.sources, Set(ExportSource.exportable))
        XCTAssertEqual([config.pastDays, config.futureDays, config.completedDays, config.whatsappChats], [365, 365, 30, 20])
    }

    func testArchiveOptions() throws {
        var config = try Config(arguments: ["archive", "--output", "/tmp/a"])
        XCTAssertEqual(config.command, .archive)
        XCTAssertEqual([config.rescanDays, config.fullSweepDays], [100, 7])
        XCTAssertFalse(config.notify)
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day, .hour], from: config.backfillSince), DateComponents(year: 2000, month: 1, day: 1, hour: 0))

        config = try Config(arguments: ["archive", "--output", "/tmp/a", "--sources", "whatsapp,reminders", "--backfill-since", "2015-03-31",
                                        "--rescan-days", "120", "--full-sweep-days", "14", "--notify", "--demo"])
        XCTAssertEqual(config.sources, [.whatsapp, .reminders])
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: config.backfillSince), DateComponents(year: 2015, month: 3, day: 31))
        XCTAssertEqual([config.rescanDays, config.fullSweepDays], [120, 14])
        XCTAssertTrue(config.notify && config.demo)
    }

    func testRebuildAndVerifyTakeOnlyOutput() throws {
        for command in ["rebuild", "verify"] {
            XCTAssertEqual(try Config(arguments: [command, "--output", "/tmp/a"]).command.rawValue, command)
            XCTAssertThrowsError(try Config(arguments: [command, "--output", "/tmp/a", "--demo"]))
            XCTAssertThrowsError(try Config(arguments: [command]))
        }
    }

    func testRejectsOptionsOfOtherCommandsAndBadValues() {
        for args in [
            ["archive", "--output", "x", "--past-days", "10"], ["export", "--output", "x", "--rescan-days", "10"], ["export", "--output", "x", "--notify"],
            ["archive", "--output", "x", "--backfill-since", "2015-02-30"], ["archive", "--output", "x", "--backfill-since", "2015-1-1"],
            ["archive", "--output", "x", "--rescan-days", "0"], ["archive", "--output", "x", "--full-sweep-days", "731"],
            ["archive", "--output", "x", "--notify", "--notify"], ["archive"], ["mirror", "--output", "x"], [],
        ] {
            XCTAssertThrowsError(try Config(arguments: args), "\(args)")
        }
    }

    func testHelpListsCommands() {
        for word in ["export --output", "archive --output", "rebuild --output", "verify --output", "--backfill-since", "--rescan-days", "--full-sweep-days", "--notify"] {
            XCTAssertTrue(Config.help.contains(word), word)
        }
    }
}
