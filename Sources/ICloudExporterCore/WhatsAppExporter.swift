import Darwin
import Foundation
import SQLite3

public enum WhatsAppExportError: Error, LocalizedError, Equatable {
    case permissionDenied
    case unrecognizedSchema
    case cannotRead

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "WhatsApp data could not be read. Allow access to other apps’ data, or grant Full Disk Access to icloud-exporter.app in System Settings → Privacy & Security, then retry."
        case .unrecognizedSchema:
            return "WhatsApp database schema is not recognized. No WhatsApp snapshot was produced."
        case .cannotRead:
            return "WhatsApp chats could not be read completely. No WhatsApp snapshot was produced."
        }
    }
}

public enum WhatsAppExporter {
    public static let defaultSourceDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
    static let appleEpoch: TimeInterval = 978_307_200
    static let missingDataWarning = "WhatsApp Desktop data was not found; skipped."

    public static func fetch(
        now: Date,
        pastDays: Int,
        chatLimit: Int = 20,
        sourceDirectory: URL? = nil
    ) throws -> SourceResult<WhatsAppChatRecord> {
        let source = (sourceDirectory ?? defaultSourceDirectory).resolvingSymlinksInPath().standardizedFileURL
        let storage = source.appendingPathComponent("ChatStorage.sqlite")
        guard FileManager.default.fileExists(atPath: source.path),
              FileManager.default.fileExists(atPath: storage.path) else {
            ExportLog.info("whatsapp: no local data")
            return SourceResult(records: [], warnings: [missingDataWarning])
        }
        guard FileManager.default.isReadableFile(atPath: storage.path) else {
            throw WhatsAppExportError.permissionDenied
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-exporter-whatsapp-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw WhatsAppExportError.cannotRead
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        ExportLog.info("whatsapp: copying local databases")
        try copySQLite(named: "ChatStorage.sqlite", from: source, to: directory)
        if FileManager.default.fileExists(atPath: source.appendingPathComponent("ContactsV2.sqlite").path) {
            try copySQLite(named: "ContactsV2.sqlite", from: source, to: directory)
        }

        let start = Calendar.current.date(byAdding: .day, value: -pastDays, to: now)!
        let chats = try read(from: directory, start: start, now: now, chatLimit: chatLimit)
        ExportLog.info("whatsapp: read \(chats.count) chats")
        return SourceResult(records: chats)
    }

    static func appleTime(_ date: Date) -> Double { date.timeIntervalSince1970 - appleEpoch }
    static func date(fromApple value: Double) -> Date { Date(timeIntervalSince1970: value + appleEpoch) }

    static func copySQLite(named name: String, from source: URL, to destination: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let from = source.appendingPathComponent(name + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            do {
                try FileManager.default.copyItem(at: from, to: destination.appendingPathComponent(name + suffix))
            } catch {
                try rethrowAccess(error)
            }
        }
    }

    static func rethrowAccess(_ error: Error) throws -> Never {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) {
            throw WhatsAppExportError.permissionDenied
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError {
            throw WhatsAppExportError.permissionDenied
        }
        throw WhatsAppExportError.cannotRead
    }

    static func read(from directory: URL, start: Date, now: Date, chatLimit: Int) throws -> [WhatsAppChatRecord] {
        let storage = try SQLiteDB(url: directory.appendingPathComponent("ChatStorage.sqlite"))
        defer { storage.close() }
        guard try storage.hasTable("ZWACHATSESSION"), try storage.hasTable("ZWAMESSAGE") else {
            throw WhatsAppExportError.unrecognizedSchema
        }
        let hasMembers = try storage.hasTable("ZWAGROUPMEMBER")
        var contacts: [String: String] = [:]
        let contactsURL = directory.appendingPathComponent("ContactsV2.sqlite")
        if FileManager.default.fileExists(atPath: contactsURL.path) {
            let book = try SQLiteDB(url: contactsURL)
            defer { book.close() }
            if try book.hasTable("ZWAADDRESSBOOKCONTACT") {
                contacts = try loadContacts(book)
            }
        }

        let windowStart = appleTime(start)
        let windowEnd = appleTime(now)
        var sessions: [(id: Int64, title: String, kind: String, jid: String)] = []
        try storage.forEach("""
            SELECT s.Z_PK, s.ZPARTNERNAME, s.ZCONTACTJID, s.ZSESSIONTYPE
            FROM ZWACHATSESSION s
            WHERE IFNULL(s.ZHIDDEN, 0) = 0
              AND IFNULL(s.ZREMOVED, 0) = 0
              AND s.ZSESSIONTYPE IN (0, 1)
              AND EXISTS (
                SELECT 1 FROM ZWAMESSAGE m
                WHERE m.ZCHATSESSION = s.Z_PK
                  AND m.ZMESSAGEDATE >= ?
                  AND m.ZMESSAGEDATE <= ?
                  AND (
                    m.ZMESSAGETYPE IN (1, 2, 3, 4, 5, 8)
                    OR (m.ZMESSAGETYPE = 0 AND m.ZTEXT IS NOT NULL AND TRIM(m.ZTEXT) != '')
                  )
              )
            ORDER BY s.ZLASTMESSAGEDATE DESC
            LIMIT ?
            """, bind: [.double(windowStart), .double(windowEnd), .int(Int64(chatLimit))]) { row in
            let id = row.int(0)
            let jid = row.text(2) ?? ""
            let kind = row.int(3) == 1 ? "group" : "direct"
            let title = firstNonEmpty(row.text(1), contacts[jid], contacts[jidUser(jid)], contacts[digits(jid)], jidUser(jid)) ?? "Chat"
            sessions.append((id, title, kind, jid))
        }

        var chats: [WhatsAppChatRecord] = []
        for session in sessions {
            var messages: [WhatsAppMessageRecord] = []
            let memberJoin = hasMembers ? "LEFT JOIN ZWAGROUPMEMBER g ON m.ZGROUPMEMBER = g.Z_PK" : ""
            let memberColumns = hasMembers ? ", g.ZCONTACTNAME, g.ZFIRSTNAME, g.ZMEMBERJID" : ", NULL, NULL, NULL"
            try storage.forEach("""
                SELECT m.Z_PK, m.ZMESSAGEDATE, m.ZISFROMME, m.ZMESSAGETYPE, m.ZTEXT, m.ZFROMJID, m.ZPUSHNAME\(memberColumns)
                FROM ZWAMESSAGE m
                \(memberJoin)
                WHERE m.ZCHATSESSION = ?
                  AND m.ZMESSAGEDATE >= ?
                  AND m.ZMESSAGEDATE <= ?
                  AND m.ZMESSAGETYPE IN (0, 1, 2, 3, 4, 5, 8)
                ORDER BY m.ZMESSAGEDATE ASC, m.Z_PK ASC
                """, bind: [.int(session.id), .double(windowStart), .double(windowEnd)]) { row in
                let type = Int(row.int(3))
                let text = nonempty(row.text(4))
                let placeholder = Self.placeholder(for: type)
                if type == 0 && text == nil { return }
                if placeholder == nil && type != 0 { return }
                let fromMe = row.int(2) == 1
                let fromJID = row.text(5) ?? ""
                let memberJID = row.text(9) ?? fromJID
                let sender: String
                if fromMe {
                    sender = "Me"
                } else if session.kind == "group" {
                    sender = firstNonEmpty(row.text(7), row.text(8), contacts[memberJID], contacts[jidUser(memberJID)],
                                           contacts[digits(memberJID)], row.text(6), jidUser(memberJID), session.title) ?? "Unknown"
                } else {
                    sender = firstNonEmpty(session.title, row.text(6), contacts[fromJID], contacts[jidUser(fromJID)],
                                           contacts[digits(fromJID)], jidUser(fromJID)) ?? "Unknown"
                }
                messages.append(WhatsAppMessageRecord(
                    id: String(row.int(0)),
                    sender: sender,
                    timestamp: date(fromApple: row.double(1)),
                    fromMe: fromMe,
                    text: text,
                    placeholder: placeholder
                ))
            }
            chats.append(WhatsAppChatRecord(id: String(session.id), title: session.title, kind: session.kind, jid: session.jid, messages: messages))
        }
        return chats
    }

    static func placeholder(for type: Int) -> String? {
        switch type {
        case 1: return "Image"
        case 2: return "Video"
        case 3: return "Audio"
        case 4: return "Contact"
        case 5: return "Location"
        case 8: return "Document"
        default: return nil
        }
    }

    static func loadContacts(_ db: SQLiteDB) throws -> [String: String] {
        var map: [String: String] = [:]
        try db.forEach("""
            SELECT ZFULLNAME, ZGIVENNAME, ZLASTNAME, ZWHATSAPPID, ZPHONENUMBER, ZLOCALIZEDPHONENUMBER, ZIDENTIFIER
            FROM ZWAADDRESSBOOKCONTACT
            """) { row in
            let name = firstNonEmpty(row.text(0), combined(row.text(1), row.text(2)))
            guard let name else { return }
            for key in [row.text(3), row.text(4), row.text(5), row.text(6)].compactMap({ $0 }) {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                map[trimmed] = name
                let user = jidUser(trimmed)
                if user != trimmed { map[user] = name }
                let phone = digits(trimmed)
                if phone.count >= 7 { map[phone] = name }
            }
        }
        return map
    }

    static func jidUser(_ jid: String) -> String {
        String(jid.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(jid))
    }

    static func digits(_ value: String) -> String { value.filter(\.isNumber) }

    static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let found = nonempty(value) { return found }
        }
        return nil
    }

    static func combined(_ given: String?, _ last: String?) -> String? {
        let parts = [nonempty(given), nonempty(last)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

final class SQLiteDB {
    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
    }

    struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
    }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw WhatsAppExportError.cannotRead
        }
        handle = db
    }

    func close() {
        sqlite3_close(handle)
        handle = nil
    }

    deinit { sqlite3_close(handle) }

    func hasTable(_ name: String) throws -> Bool {
        var found = false
        try forEach("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", bind: [.text(name)]) { _ in found = true }
        return found
    }

    func forEach(_ sql: String, bind: [Value] = [], _ body: (Row) throws -> Void) throws {
        guard let handle else { throw WhatsAppExportError.cannotRead }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WhatsAppExportError.unrecognizedSchema
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() {
            let status: Int32
            switch value {
            case .int(let number): status = sqlite3_bind_int64(statement, Int32(index + 1), number)
            case .double(let number): status = sqlite3_bind_double(statement, Int32(index + 1), number)
            case .text(let text): status = sqlite3_bind_text(statement, Int32(index + 1), text, -1, Self.transient)
            }
            guard status == SQLITE_OK else { throw WhatsAppExportError.cannotRead }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw WhatsAppExportError.cannotRead }
            try body(Row(statement: statement))
        }
    }
}
