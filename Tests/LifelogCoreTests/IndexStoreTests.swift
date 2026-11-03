import Foundation
import XCTest
@testable import LifelogCore

/// The SQLite index cache reads only appended ledger lines, and folds everything again whenever that would be wrong.
final class IndexStoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_788_780_000)

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func added(_ id: String, at: Date) -> LedgerEvent {
        let record = NoteRecord(id: id, title: "Note \(id)", account: "iCloud", folder: "Notes", created: now, modified: now, bodyHTML: "<p>\(id)</p>")
        let item = ArchivedItem(key: ItemKey(source: .notes, id: id), nativeID: id, partition: Partition(date: "2026-09-07", utcOffset: 0),
                                stateSince: at, contentHash: id, payload: .note(record))
        return LedgerEvent(type: .added, at: at, run: "r", key: item.key, item: item)
    }

    /// Removes an item from the cache only, so a later load shows whether it read the cache or folded the ledger again.
    func forget(_ id: String, in store: IndexStore) throws {
        try SQLite(store.url).run("DELETE FROM items WHERE id = ?", [.text(id)])
    }

    func setUp(_ root: URL, _ cache: URL) throws -> (Ledger, IndexStore) {
        let ledger = Ledger(root: root, host: "mac1")
        try ledger.append([added("n1", at: now), added("n2", at: now + 1)])
        XCTAssertEqual(try ArchiveIndex.load(ledger, cacheRoot: cache).items.count, 2)
        return (ledger, IndexStore(ledger: ledger, cacheRoot: cache))
    }

    func testAppendedLinesAreReadOnTopOfTheCache() throws {
        let (ledger, store) = try setUp(try temporaryDirectory(), try temporaryDirectory())
        try forget("n1", in: store)
        try ledger.append([added("n3", at: now + 2)])
        try Ledger(root: ledger.root, host: "mac2").append([added("n4", at: now + 3)])
        let index = try store.load()
        XCTAssertEqual(index.items.keys.map(\.id).sorted(), ["n2", "n3", "n4"], "only the new lines were read")
        XCTAssertEqual(try store.load().items.keys.map(\.id).sorted(), ["n2", "n3", "n4"], "and the cache now holds them")
        XCTAssertEqual(store.snapshot()?.upToDate, true)
    }

    func testOlderLinesFromAnotherMacFoldAgain() throws {
        let (ledger, store) = try setUp(try temporaryDirectory(), try temporaryDirectory())
        try forget("n1", in: store)
        try Ledger(root: ledger.root, host: "mac2").append([added("n0", at: now - 60)])
        let index = try store.load()
        XCTAssertEqual(index.items.keys.map(\.id).sorted(), ["n0", "n1", "n2"])
        XCTAssertEqual(index, ArchiveIndex.fold(try ledger.read().events))
    }

    func testRewrittenOrShrunkFilesFoldAgain() throws {
        let (ledger, store) = try setUp(try temporaryDirectory(), try temporaryDirectory())
        let folder = ledger.directory.appendingPathComponent("notes")
        let file = folder.appendingPathComponent(try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: folder.path).first))
        let original = try Data(contentsOf: file)

        // Same lines in another order, plus one: the bytes before the read position changed.
        let lines = original.split(separator: 0x0A).map { Data($0) }
        try (Data(lines.reversed().joined(separator: [0x0A])) + Data([0x0A]) + JSONLines.encoder.encode(added("n3", at: now + 2)) + Data([0x0A])).write(to: file)
        try forget("n1", in: store)
        XCTAssertEqual(try store.load().items.keys.map(\.id).sorted(), ["n1", "n2", "n3"])

        try original.write(to: file)
        try forget("n1", in: store)
        XCTAssertEqual(try store.load().items.keys.map(\.id).sorted(), ["n1", "n2"])
    }

    func testSaveWritesTheItemsArchivedThisRun() throws {
        let cache = try temporaryDirectory()
        let (ledger, store) = try setUp(try temporaryDirectory(), cache)
        var index = try ArchiveIndex.load(ledger, cacheRoot: cache)
        let events = try JSONLines.stored([added("n3", at: now + 2)])
        try ledger.append(events)
        for event in events { index.apply(event) }
        index.save(ledger, cacheRoot: cache)
        try forget("n1", in: store)
        XCTAssertEqual(try store.load().items.keys.map(\.id).sorted(), ["n2", "n3"], "the save counted this Mac's appends as read")
        XCTAssertEqual(store.snapshot()?.upToDate, true)
    }
}
