import Foundation
import XCTest
@testable import LifelogCore

/// A synthetic BackLog library in the shape of its SwiftData store: one `ZITEM` table, UUIDs as blobs,
/// dates as seconds since 2001.
enum BackLogFixture {
    static let schema = """
        CREATE TABLE ZITEM ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZADDEDAT TIMESTAMP, ZCONSUMEDAT TIMESTAMP, ZDURATIONSECONDS FLOAT,
        ZPOSITION FLOAT, ZSORTINDEX FLOAT, ZAUTHOR VARCHAR, ZCANONICALURL VARCHAR, ZKINDRAW VARCHAR, ZNOTE VARCHAR, ZSHAREDBY VARCHAR, ZSTATERAW VARCHAR,
        ZSUMMARYJSON VARCHAR, ZTHUMBNAILURL VARCHAR, ZTITLE VARCHAR, ZURLSTRING VARCHAR, ZID BLOB , ZIMAGELABELS VARCHAR, ZPUBLISHEDAT TIMESTAMP,
        ZDETAILS VARCHAR, ZSEARCHTEXT VARCHAR, ZCAPTUREDAT TIMESTAMP, ZIMAGETEXT VARCHAR, ZSITENAME VARCHAR, ZSTARRED INTEGER, ZTRANSCRIPTJSON VARCHAR);
        """

    struct Row {
        var id: String
        var state = "done", kind = "video", title = "A talk", url = "https://example.com/v/1"
        var added: Date, consumed: Date?
        var author = "Example Channel", sharedBy = "", note = "", summary = "", duration = 0.0
    }

    static func write(_ rows: [Row], to store: URL) throws {
        try? FileManager.default.removeItem(at: store)
        let db = try SQLite(store)
        try db.execute(schema)
        for row in rows {
            let hex = row.id.replacingOccurrences(of: "-", with: "")
            try db.execute("""
                INSERT INTO ZITEM (ZID, ZSTATERAW, ZKINDRAW, ZTITLE, ZURLSTRING, ZADDEDAT, ZCONSUMEDAT, ZAUTHOR, ZSITENAME, ZSHAREDBY, ZNOTE, ZDETAILS, ZSUMMARYJSON, ZDURATIONSECONDS)
                VALUES (X'\(hex)', '\(row.state)', '\(row.kind)', '\(row.title)', '\(row.url)', \(WhatsAppExporter.appleTime(row.added)),
                        \(row.consumed.map { String(WhatsAppExporter.appleTime($0)) } ?? "NULL"), '\(row.author)', '', '\(row.sharedBy)', '\(row.note)', '', '\(row.summary)', \(row.duration))
                """)
        }
    }
}

final class BackLogReaderTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let t0 = Date(timeIntervalSince1970: 1_762_000_000) // 2025-11-01

    func store() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("Library.store")
    }

    func testOnlyFinishedItemsAreRead() throws {
        let url = try store()
        let summary = #"{"takeaway":"Noise protects ears.","keyPoints":[{"seconds":0,"text":"Pink noise before impact."}],"allPoints":[]}"#
        try BackLogFixture.write([
            .init(id: "0A1B2C3D-0000-4000-8000-000000000001", added: t0, consumed: t0 + 3600, sharedBy: "Anna · WhatsApp", note: "Good one #cars", summary: summary, duration: 754),
            .init(id: "0A1B2C3D-0000-4000-8000-000000000002", state: "queued", added: t0, consumed: nil),
            .init(id: "0A1B2C3D-0000-4000-8000-000000000003", state: "skipped", kind: "article", title: "Long read", url: "https://example.org/a", added: t0, consumed: t0 + 7200, author: "example.org"),
        ], to: url)

        let items = try BackLogReader.read(store: url)
        XCTAssertEqual(items.map(\.id), ["0a1b2c3d-0000-4000-8000-000000000001", "0a1b2c3d-0000-4000-8000-000000000003"])
        XCTAssertEqual(items[0].consumed, t0 + 3600)
        XCTAssertEqual(items[0].takeaway, "Noise protects ears.")
        XCTAssertEqual(items[0].keyPoints, ["Pink noise before impact."])

        let watched = BackLogReader.entry(items[0], timeZone: utc)
        XCTAssertEqual(watched.container, "history/2025-11")
        XCTAssertEqual(watched.containerTitle, "History 2025-11")
        XCTAssertEqual(watched.label, "Watched · Video")
        XCTAssertEqual(watched.text, """
            [A talk](https://example.com/v/1)
            Example Channel · 13 min · from Anna · WhatsApp

            > Noise protects ears.

            - Pink noise before impact.

            Good one #cars
            """)
        XCTAssertEqual(BackLogReader.entry(items[1], timeZone: utc).label, "Skipped · Article")
    }

    func testAMissingLibraryFailsTheRead() throws {
        let url = try store()
        XCTAssertThrowsError(try BackLogReader.read(store: url))
    }
}

extension ArchiverTests {
    /// The first run archives every finished item; an item put back in the queue goes pending, then deleted.
    func testBackLogHistoryIsArchived() async throws {
        let root = try temporaryDirectory()
        let store = try temporaryDirectory().appendingPathComponent("Library.store")
        let rows: [BackLogFixture.Row] = [
            .init(id: "0A1B2C3D-0000-4000-8000-000000000001", added: t0, consumed: t0 + 60),
            .init(id: "0A1B2C3D-0000-4000-8000-000000000002", kind: "podcast", title: "An episode", url: "https://example.com/p/2", added: t0, consumed: t0 + 120),
        ]
        try BackLogFixture.write(rows, to: store)
        let reader = BackLogArchiveReader(store: store)
        let first = try await archiver(root).run([reader], now: t0 + day)
        XCTAssertEqual(first.added, 2)
        let pages = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("BackLog").path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(pages.count, 1)
        let page = try String(contentsOf: root.appendingPathComponent("BackLog/\(pages[0])"), encoding: .utf8)
        XCTAssertTrue(page.contains("Listened · Podcast"), page)
        XCTAssertTrue(page.contains("[An episode](https://example.com/p/2)"), page)

        let again = try await archiver(root).run([reader], now: t0 + 2 * day)
        XCTAssertEqual(again.added, 0)

        var requeued = rows
        requeued[1].state = "queued"
        try BackLogFixture.write(requeued, to: store)
        _ = try await archiver(root).run([reader], now: t0 + 3 * day)
        let item = try XCTUnwrap(archiver(root).index.items.values.first { $0.nativeID == "0a1b2c3d-0000-4000-8000-000000000002" })
        XCTAssertNotNil(item.missingSince)
    }
}
