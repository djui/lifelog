import Foundation
import SQLite3
import XCTest
@testable import ICloudExporterCore

final class WhatsAppExporterTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_788_780_000)

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMissingDirectoryWarnsAndReturnsNothing() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let result = try WhatsAppExporter.fetch(now: now, pastDays: 30, sourceDirectory: missing)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.warnings, [WhatsAppExporter.missingDataWarning])
    }

    func testTopTwentySkipsHiddenBroadcastAndOlderChats() throws {
        let source = try fixture()
        var sql = schema
        for index in 1...22 {
            sql += chat(id: index, name: "Chat \(index)", last: now.addingTimeInterval(TimeInterval(index) * 3600), text: "Hello \(index)")
        }
        sql += chat(id: 100, name: "Hidden", last: now.addingTimeInterval(100_000), text: "secret", hidden: 1)
        sql += chat(id: 101, name: "Broadcast", last: now.addingTimeInterval(99_000), text: "blast", type: 2)
        try exec(source.appendingPathComponent("ChatStorage.sqlite"), sql)

        let result = try WhatsAppExporter.fetch(now: now.addingTimeInterval(200_000), pastDays: 365, chatLimit: 20, sourceDirectory: source)
        XCTAssertEqual(result.records.map(\.id), (3...22).reversed().map(String.init))
        XCTAssertFalse(result.records.contains { $0.title == "Hidden" || $0.title == "Broadcast" || $0.title == "Chat 1" || $0.title == "Chat 2" })
    }

    func testPastDaysKeepsRecentMessagesOnly() throws {
        let source = try fixture()
        let recent = now.addingTimeInterval(-3600)
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        var sql = schema
        sql += chat(id: 1, name: "Mixed", last: recent, text: nil)
        sql += message(id: 10, chat: 1, at: old, text: "old")
        sql += message(id: 11, chat: 1, at: recent, text: "new")
        sql += chat(id: 2, name: "Stale", last: old, text: "only old")
        try exec(source.appendingPathComponent("ChatStorage.sqlite"), sql)

        let result = try WhatsAppExporter.fetch(now: now, pastDays: 30, chatLimit: 20, sourceDirectory: source)
        XCTAssertEqual(result.records.map(\.title), ["Mixed"])
        XCTAssertEqual(result.records[0].messages.map(\.text), ["new"])
    }

    func testMediaPlaceholderAndCaption() throws {
        let source = try fixture()
        let at = now.addingTimeInterval(-60)
        var sql = schema
        sql += chat(id: 1, name: "Photos", last: at, text: nil)
        sql += message(id: 1, chat: 1, at: at, text: nil, type: 1)
        sql += message(id: 2, chat: 1, at: at.addingTimeInterval(1), text: "Look at this", type: 1)
        sql += message(id: 3, chat: 1, at: at.addingTimeInterval(2), text: "system noise", type: 10)
        try exec(source.appendingPathComponent("ChatStorage.sqlite"), sql)

        let result = try WhatsAppExporter.fetch(now: now, pastDays: 30, sourceDirectory: source)
        XCTAssertEqual(result.records[0].messages.map(\.placeholder), ["Image", "Image"])
        XCTAssertEqual(result.records[0].messages.map(\.text), [nil, "Look at this"])
    }

    func testLinkAndOtherTextTypesAreExported() throws {
        let source = try fixture()
        let at = now.addingTimeInterval(-60)
        var sql = schema
        sql += chat(id: 1, name: "Links only", last: at, text: nil)
        sql += message(id: 1, chat: 1, at: at, text: "https://example.com", type: 7)
        sql += message(id: 2, chat: 1, at: at.addingTimeInterval(1), text: "poll question", type: 41)
        sql += message(id: 3, chat: 1, at: at.addingTimeInterval(2), text: nil, type: 43)
        sql += message(id: 4, chat: 1, at: at.addingTimeInterval(3), text: "deleted stub", type: 14)
        try exec(source.appendingPathComponent("ChatStorage.sqlite"), sql)

        let result = try WhatsAppExporter.fetch(now: now, pastDays: 30, sourceDirectory: source)
        XCTAssertEqual(result.records.map(\.title), ["Links only"])
        XCTAssertEqual(result.records[0].messages.map(\.text), ["https://example.com", "poll question"])
        XCTAssertEqual(result.records[0].messages.map(\.placeholder), [nil, nil])
    }

    func testResolvesContactAndGroupSenders() throws {
        let source = try fixture()
        let at = now.addingTimeInterval(-120)
        var sql = schema
        sql += """
        INSERT INTO ZWACHATSESSION (Z_PK, ZHIDDEN, ZREMOVED, ZSESSIONTYPE, ZLASTMESSAGEDATE, ZCONTACTJID, ZPARTNERNAME)
        VALUES (1, 0, 0, 0, \(apple(at)), '15555550199@s.whatsapp.net', NULL);
        INSERT INTO ZWAMESSAGE (Z_PK, ZISFROMME, ZMESSAGETYPE, ZCHATSESSION, ZGROUPMEMBER, ZMESSAGEDATE, ZFROMJID, ZTEXT)
        VALUES (1, 0, 0, 1, NULL, \(apple(at)), '15555550199@s.whatsapp.net', 'from sam');
        INSERT INTO ZWACHATSESSION (Z_PK, ZHIDDEN, ZREMOVED, ZSESSIONTYPE, ZLASTMESSAGEDATE, ZCONTACTJID, ZPARTNERNAME)
        VALUES (2, 0, 0, 1, \(apple(at.addingTimeInterval(1))), '120363@g.us', 'Trip planning');
        INSERT INTO ZWAGROUPMEMBER (Z_PK, ZCONTACTNAME, ZFIRSTNAME, ZMEMBERJID)
        VALUES (7, 'Blair', 'B', '15555550111@s.whatsapp.net');
        INSERT INTO ZWAMESSAGE (Z_PK, ZISFROMME, ZMESSAGETYPE, ZCHATSESSION, ZGROUPMEMBER, ZMESSAGEDATE, ZFROMJID, ZPUSHNAME, ZTEXT)
        VALUES (2, 0, 0, 2, 7, \(apple(at.addingTimeInterval(1))), '15555550111@s.whatsapp.net', 'push', 'from blair');
        INSERT INTO ZWAMESSAGE (Z_PK, ZISFROMME, ZMESSAGETYPE, ZCHATSESSION, ZGROUPMEMBER, ZMESSAGEDATE, ZTEXT)
        VALUES (3, 1, 0, 2, NULL, \(apple(at.addingTimeInterval(2))), 'from me');
        """
        try exec(source.appendingPathComponent("ChatStorage.sqlite"), sql)
        try exec(source.appendingPathComponent("ContactsV2.sqlite"), """
        CREATE TABLE ZWAADDRESSBOOKCONTACT (
          Z_PK INTEGER PRIMARY KEY, ZFULLNAME VARCHAR, ZGIVENNAME VARCHAR, ZLASTNAME VARCHAR,
          ZWHATSAPPID VARCHAR, ZPHONENUMBER VARCHAR, ZLOCALIZEDPHONENUMBER VARCHAR, ZIDENTIFIER VARCHAR
        );
        INSERT INTO ZWAADDRESSBOOKCONTACT (Z_PK, ZFULLNAME, ZWHATSAPPID)
        VALUES (1, 'Sam Rivera', '15555550199');
        """)

        let result = try WhatsAppExporter.fetch(now: now, pastDays: 30, sourceDirectory: source)
        let direct = result.records.first { $0.kind == "direct" }
        let group = result.records.first { $0.kind == "group" }
        XCTAssertEqual(direct?.title, "Sam Rivera")
        XCTAssertEqual(direct?.messages.first?.sender, "Sam Rivera")
        XCTAssertEqual(group?.title, "Trip planning")
        XCTAssertEqual(group?.messages.map(\.sender), ["Blair", "Me"])
    }

    func testUnrecognizedSchemaFails() throws {
        let source = try fixture()
        try exec(source.appendingPathComponent("ChatStorage.sqlite"), "CREATE TABLE Z_METADATA (Z_PK INTEGER PRIMARY KEY);")
        XCTAssertThrowsError(try WhatsAppExporter.fetch(now: now, pastDays: 30, sourceDirectory: source)) { error in
            XCTAssertEqual(error as? WhatsAppExportError, .unrecognizedSchema)
        }
    }

    func testMarkdownUsesWhatsAppDirectoryAndPlaceholders() throws {
        let config = try Config(arguments: ["export", "--output", "/tmp/unused", "--sources", "whatsapp"])
        let snapshot = Demo.snapshot(now: now)
        let docs = try MarkdownWriter.documents(snapshot: snapshot, config: config, now: now)
        XCTAssertEqual(docs.count, 1)
        XCTAssertTrue(docs[0].path.hasPrefix("WhatsApp/alex--"))
        XCTAssertTrue(docs[0].path.hasSuffix(".md"))
        XCTAssertFalse(docs[0].path.hasPrefix("Whatsapp/"))
        XCTAssertTrue(docs[0].content.contains("**Me:** Want to compare a few trail options this week?"))
        XCTAssertTrue(docs[0].content.contains("**Alex:** [Image]"))
        XCTAssertTrue(docs[0].content.contains("kind: \"direct\""))
    }

    func testStoreIndexUsesWhatsAppDisplayName() throws {
        let root = try temporaryDirectory()
        let store = ExportStore(output: root)
        _ = try store.write(
            [ExportDocument(path: "WhatsApp/a.md", content: "example", source: .whatsapp)],
            sources: [.whatsapp], now: now, demo: true, warnings: [:]
        )
        let index = try String(contentsOf: root.appendingPathComponent("_index.md"))
        XCTAssertTrue(index.contains("## WhatsApp"))
        XCTAssertFalse(index.contains("## Whatsapp"))
    }

    func testConfigAcceptsWhatsAppSource() throws {
        let config = try Config(arguments: ["export", "--output", "/tmp/x", "--sources", "notes,whatsapp"])
        XCTAssertEqual(config.sources, [.notes, .whatsapp])
        XCTAssertEqual(config.whatsappChats, 20)
    }

    func fixture() throws -> URL { try temporaryDirectory() }

    var schema: String {
        """
        CREATE TABLE ZWACHATSESSION (
          Z_PK INTEGER PRIMARY KEY, ZHIDDEN INTEGER, ZREMOVED INTEGER, ZSESSIONTYPE INTEGER,
          ZLASTMESSAGEDATE TIMESTAMP, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR
        );
        CREATE TABLE ZWAMESSAGE (
          Z_PK INTEGER PRIMARY KEY, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER, ZCHATSESSION INTEGER,
          ZGROUPMEMBER INTEGER, ZMEDIAITEM INTEGER, ZMESSAGEDATE TIMESTAMP, ZFROMJID VARCHAR,
          ZPUSHNAME VARCHAR, ZTEXT VARCHAR
        );
        CREATE TABLE ZWAGROUPMEMBER (
          Z_PK INTEGER PRIMARY KEY, ZCONTACTNAME VARCHAR, ZFIRSTNAME VARCHAR, ZMEMBERJID VARCHAR
        );
        CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR);
        """
    }

    func chat(id: Int, name: String, last: Date, text: String?, hidden: Int = 0, type: Int = 0) -> String {
        var sql = """
        INSERT INTO ZWACHATSESSION (Z_PK, ZHIDDEN, ZREMOVED, ZSESSIONTYPE, ZLASTMESSAGEDATE, ZCONTACTJID, ZPARTNERNAME)
        VALUES (\(id), \(hidden), 0, \(type), \(apple(last)), '\(id)@s.whatsapp.net', '\(name)');
        """
        if let text {
            sql += message(id: id, chat: id, at: last, text: text)
        }
        return sql
    }

    func message(id: Int, chat: Int, at: Date, text: String?, type: Int = 0) -> String {
        let value = text.map { "'\($0)'" } ?? "NULL"
        return """
        INSERT INTO ZWAMESSAGE (Z_PK, ZISFROMME, ZMESSAGETYPE, ZCHATSESSION, ZMESSAGEDATE, ZTEXT)
        VALUES (\(id), 1, \(type), \(chat), \(apple(at)), \(value));
        """
    }

    func apple(_ date: Date) -> String { String(WhatsAppExporter.appleTime(date)) }

    func exec(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            XCTFail("Could not create fixture at \(url.path)")
            throw WhatsAppExportError.cannotRead
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &err)
        if status != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            XCTFail(message)
            throw WhatsAppExportError.cannotRead
        }
    }
}
