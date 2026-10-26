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
        try withLocalCopy(of: sourceDirectory) { directory in
            let start = Calendar.current.date(byAdding: .day, value: -pastDays, to: now)!
            let chats = try read(from: directory, start: start, now: now, chatLimit: chatLimit)
            ExportLog.info("whatsapp: read \(chats.count) chats")
            return SourceResult(records: chats)
        }
    }

    /// Everything the archive needs: every 1:1 and group chat (removed and hidden ones
    /// flagged, not dropped) and every message type since `since`.
    public static func fetchArchive(
        since: Date,
        now: Date,
        sourceDirectory: URL? = nil
    ) throws -> SourceResult<WhatsAppChatRecord> {
        try withLocalCopy(of: sourceDirectory) { directory in
            let result = try readArchive(from: directory, since: since, now: now)
            ExportLog.info("whatsapp: read \(result.records.count) chats for the archive")
            return result
        }
    }

    static func withLocalCopy(
        of sourceDirectory: URL?,
        _ body: (URL) throws -> SourceResult<WhatsAppChatRecord>
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

        return try body(directory)
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
        let contacts = try loadContacts(in: directory)

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
                messages.append(WhatsAppMessageRecord(
                    id: String(row.int(0)),
                    sender: sender(fromMe: fromMe, fromJID: row.text(5), pushName: row.text(6),
                                   memberName: row.text(7), memberFirstName: row.text(8), memberJID: row.text(9),
                                   chatKind: session.kind, chatTitle: session.title, contacts: contacts),
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

    static func readArchive(from directory: URL, since: Date, now: Date) throws -> SourceResult<WhatsAppChatRecord> {
        let storage = try SQLiteDB(url: directory.appendingPathComponent("ChatStorage.sqlite"))
        defer { storage.close() }
        guard try storage.hasTable("ZWACHATSESSION"), try storage.hasTable("ZWAMESSAGE") else {
            throw WhatsAppExportError.unrecognizedSchema
        }
        for column in ["Z_PK", "ZCONTACTJID", "ZSESSIONTYPE"] {
            guard try storage.hasColumn(table: "ZWACHATSESSION", column: column) else { throw WhatsAppExportError.unrecognizedSchema }
        }
        for column in ["Z_PK", "ZCHATSESSION", "ZMESSAGEDATE", "ZISFROMME", "ZMESSAGETYPE", "ZTEXT"] {
            guard try storage.hasColumn(table: "ZWAMESSAGE", column: column) else { throw WhatsAppExportError.unrecognizedSchema }
        }
        // Optional columns degrade to NULL so a WhatsApp update cannot make whole chats look deleted.
        func optional(_ table: String, _ alias: String, _ column: String) throws -> String {
            try storage.hasColumn(table: table, column: column) ? "\(alias).\(column)" : "NULL"
        }
        var warnings: [String] = []
        let contacts = try loadContacts(in: directory)

        var sessions: [Int64: WhatsAppChatRecord] = [:]
        var order: [Int64] = []
        try storage.forEach("""
            SELECT s.Z_PK, \(try optional("ZWACHATSESSION", "s", "ZPARTNERNAME")), s.ZCONTACTJID, s.ZSESSIONTYPE,
                   \(try optional("ZWACHATSESSION", "s", "ZREMOVED")), \(try optional("ZWACHATSESSION", "s", "ZHIDDEN"))
            FROM ZWACHATSESSION s
            WHERE s.ZSESSIONTYPE IN (0, 1)
            ORDER BY s.Z_PK ASC
            """) { row in
            let id = row.int(0)
            let jid = row.text(2) ?? ""
            let kind = row.int(3) == 1 ? "group" : "direct"
            let title = firstNonEmpty(row.text(1), contacts[jid], contacts[jidUser(jid)], contacts[digits(jid)], jidUser(jid)) ?? "Chat"
            sessions[id] = WhatsAppChatRecord(id: String(id), title: title, kind: kind, jid: jid, messages: [],
                                              isRemoved: row.int(4) != 0, isHidden: row.int(5) != 0)
            order.append(id)
        }

        let hasStanza = try storage.hasColumn(table: "ZWAMESSAGE", column: "ZSTANZAID")
        if !hasStanza {
            warnings.append("WhatsApp messages have no stanza ids in this database version; archive keys fall back to row ids.")
        }
        let hasMembers = try storage.hasTable("ZWAGROUPMEMBER") && storage.hasColumn(table: "ZWAMESSAGE", column: "ZGROUPMEMBER")
        let memberJoin = hasMembers ? "LEFT JOIN ZWAGROUPMEMBER g ON m.ZGROUPMEMBER = g.Z_PK" : ""
        let memberColumns = hasMembers
            ? "\(try optional("ZWAGROUPMEMBER", "g", "ZCONTACTNAME")), \(try optional("ZWAGROUPMEMBER", "g", "ZFIRSTNAME")), \(try optional("ZWAGROUPMEMBER", "g", "ZMEMBERJID"))"
            : "NULL, NULL, NULL"
        try storage.forEach("""
            SELECT m.Z_PK, m.ZCHATSESSION, m.ZMESSAGEDATE, m.ZISFROMME, m.ZMESSAGETYPE, m.ZTEXT,
                   \(try optional("ZWAMESSAGE", "m", "ZFROMJID")), \(try optional("ZWAMESSAGE", "m", "ZPUSHNAME")), \(memberColumns),
                   \(hasStanza ? "m.ZSTANZAID" : "NULL"), \(try optional("ZWAMESSAGE", "m", "ZSENTDATE"))
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION s ON m.ZCHATSESSION = s.Z_PK
            \(memberJoin)
            WHERE s.ZSESSIONTYPE IN (0, 1)
              AND m.ZMESSAGEDATE >= ?
              AND m.ZMESSAGEDATE <= ?
            ORDER BY m.ZCHATSESSION ASC, m.ZMESSAGEDATE ASC, m.Z_PK ASC
            """, bind: [.double(appleTime(since)), .double(appleTime(now))]) { row in
            let sessionID = row.int(1)
            guard let chat = sessions[sessionID] else { return }
            let type = Int(row.int(4))
            let kind = archiveKind(for: type)
            let fromMe = row.int(3) == 1
            let message = WhatsAppMessageRecord(
                id: String(row.int(0)),
                sender: sender(fromMe: fromMe, fromJID: row.text(6), pushName: row.text(7),
                               memberName: row.text(8), memberFirstName: row.text(9), memberJID: row.text(10),
                               chatKind: chat.kind, chatTitle: chat.title, contacts: contacts),
                timestamp: date(fromApple: row.double(2)),
                fromMe: fromMe,
                text: kind == .revoked ? nil : nonempty(row.text(5)),
                placeholder: kind.placeholder,
                stanzaID: nonempty(row.text(11)),
                rawType: type,
                isRevoked: kind == .revoked,
                isSystem: kind == .system,
                sentDate: row.isNull(12) ? nil : date(fromApple: row.double(12))
            )
            sessions[sessionID]?.messages.append(message)
        }
        return SourceResult(records: order.compactMap { sessions[$0] }, warnings: warnings)
    }

    enum ArchiveKind: Equatable {
        case text, system, revoked
        case media(String)
        case other(Int)

        var placeholder: String? {
            switch self {
            case .text, .system, .revoked: return nil
            case .media(let label): return label
            case .other(let type): return "Message type \(type)"
            }
        }
    }

    /// Phase 0 probes: 7 carries link previews and 41–43 carry text, so they count as messages.
    static func archiveKind(for type: Int) -> ArchiveKind {
        switch type {
        case 0, 7, 41, 42, 43: return .text
        case 6, 10: return .system
        case 14: return .revoked
        default:
            if let label = placeholder(for: type) { return .media(label) }
            return .other(type)
        }
    }

    static func sender(
        fromMe: Bool, fromJID: String?, pushName: String?,
        memberName: String?, memberFirstName: String?, memberJID: String?,
        chatKind: String, chatTitle: String, contacts: [String: String]
    ) -> String {
        let fromJID = fromJID ?? ""
        let memberJID = memberJID ?? fromJID
        if fromMe {
            return "Me"
        } else if chatKind == "group" {
            return firstNonEmpty(memberName, memberFirstName, contacts[memberJID], contacts[jidUser(memberJID)],
                                 contacts[digits(memberJID)], pushName, jidUser(memberJID), chatTitle) ?? "Unknown"
        } else {
            return firstNonEmpty(chatTitle, pushName, contacts[fromJID], contacts[jidUser(fromJID)],
                                 contacts[digits(fromJID)], jidUser(fromJID)) ?? "Unknown"
        }
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

    static func loadContacts(in directory: URL) throws -> [String: String] {
        let contactsURL = directory.appendingPathComponent("ContactsV2.sqlite")
        guard FileManager.default.fileExists(atPath: contactsURL.path) else { return [:] }
        let book = try SQLiteDB(url: contactsURL)
        defer { book.close() }
        guard try book.hasTable("ZWAADDRESSBOOKCONTACT") else { return [:] }
        return try loadContacts(book)
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
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
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

    func hasColumn(table: String, column: String) throws -> Bool {
        var found = false
        try forEach("SELECT 1 FROM pragma_table_info(?) WHERE name = ?", bind: [.text(table), .text(column)]) { _ in found = true }
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
