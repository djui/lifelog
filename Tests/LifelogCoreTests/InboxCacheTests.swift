import XCTest
@testable import LifelogCore

/// Synthetic files and zips only.
@MainActor
final class InboxCacheTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDigestIsReusedWhileSizeAndTimeMatch() throws {
        let folder = try temporaryDirectory()
        let cacheFile = folder.appendingPathComponent("cache/ai-inbox-digests.json")
        let a = folder.appendingPathComponent("a.zip"), b = folder.appendingPathComponent("b.zip")
        try Data("first".utf8).write(to: a)
        try Data("second".utf8).write(to: b)

        let first = ZipDigests(file: cacheFile)
        let digestA = try first.digest(a)
        XCTAssertEqual(digestA, try AIExportImporter.fileDigest(a))
        _ = try first.digest(b)
        XCTAssertEqual(first.hashed, 2)
        first.save()

        let second = ZipDigests(file: cacheFile)
        XCTAssertEqual(try second.digest(a), digestA)
        XCTAssertEqual(second.hashed, 0)

        // New contents with a new size or time are hashed again; a zip no longer seen drops out.
        try Data("first, edited".utf8).write(to: a)
        let third = ZipDigests(file: cacheFile)
        XCTAssertNotEqual(try third.digest(a), digestA)
        XCTAssertEqual(third.hashed, 1)
        third.save()
        let saved = try JSONLines.decoder.decode([String: ZipDigests.Entry].self, from: Data(contentsOf: cacheFile))
        XCTAssertEqual(Set(saved.keys), [a.standardizedFileURL.path])
    }

    func testInboxScanUsesTheCache() throws {
        let inbox = try temporaryDirectory(), cache = try temporaryDirectory()
        let cacheFile = cache.appendingPathComponent("ai-inbox-digests.json")
        try Data("PK\u{03}\u{04}not really a zip".utf8).write(to: inbox.appendingPathComponent("broken.zip"))
        try Data("plain".utf8).write(to: inbox.appendingPathComponent("notes.txt"))

        let first = AIInbox(url: inbox, digestCache: cacheFile).exports(skipping: [])
        XCTAssertEqual(first.warnings.count, 1, "a broken zip still warns")
        let saved = try JSONLines.decoder.decode([String: ZipDigests.Entry].self, from: Data(contentsOf: cacheFile))
        XCTAssertEqual(saved.count, 1, "only zips are hashed")

        // A known digest skips the zip without unpacking it, and without hashing it again.
        let digest = try XCTUnwrap(saved.values.first?.digest)
        let cached = ZipDigests(file: cacheFile)
        let again = AIExportImporter.scan(inbox: inbox, skipDigests: [digest], digest: cached.digest)
        XCTAssertEqual(again.warnings, [])
        XCTAssertEqual(cached.hashed, 0)
    }
}
