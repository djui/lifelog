import Foundation
import Darwin

public enum LedgerEventType: String, Codable {
    case added, changed, stateChanged, rekeyed, missingPending, missingCleared
}

/// One line of the ledger. `item` is set for added/changed, `state` for stateChanged, `newKey` for rekeyed.
public struct LedgerEvent: Codable, Equatable {
    public var v: Int
    public var type: LedgerEventType
    public var at: Date
    public var run: String
    public var key: ItemKey
    public var item: ArchivedItem?
    public var state: LifecycleState?
    public var reason: String?
    public var newKey: ItemKey?

    public init(type: LedgerEventType, at: Date, run: String, key: ItemKey, item: ArchivedItem? = nil, state: LifecycleState? = nil, reason: String? = nil, newKey: ItemKey? = nil) {
        v = Self.currentVersion; self.type = type; self.at = at; self.run = run; self.key = key
        self.item = item; self.state = state; self.reason = reason; self.newKey = newKey
    }
}

public struct LedgerContents {
    /// Events of every host, in timestamp order.
    public var events: [LedgerEvent] = []
    /// Torn last lines, unreadable lines and unexpected files. Reading never fails on these.
    public var issues: [String] = []
    /// Lines and source folders a newer Lifelog wrote. They are not in `events`.
    public var newer = NewerLines()
}

/// Append-only JSONL month files under `.archive/ledger/<source>/<YYYY-MM>.<host>.jsonl`.
/// Each Mac writes only its own files, so a sync client never sees two writers on one file.
public struct Ledger {
    public static let folderName = ".archive"
    public let root: URL
    public let host: String

    public init(root: URL, host: String) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.host = host
    }

    public var directory: URL { root.appendingPathComponent(Self.folderName).appendingPathComponent("ledger") }

    /// Refuses folders written by `export`, so the mirror never deletes archive pages or the other way round.
    public static func checkFolder(_ root: URL) throws {
        for name in [ExportStore.manifestName, ExportStore.pendingName] where FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            throw ExportError.message("Output folder holds an export (\(name)). Choose a separate folder for the archive.")
        }
    }

    /// Appends one run's batch, grouped by source and append month, with one fsync per file.
    public func append(_ events: [LedgerEvent]) throws {
        let groups = Dictionary(grouping: events) { "\($0.key.source.rawValue)/\(JSONLines.month($0.at))" }
        for (group, batch) in groups.sorted(by: { $0.key < $1.key }) {
            let source = String(group.split(separator: "/")[0])
            let month = String(group.split(separator: "/")[1])
            let folder = directory.appendingPathComponent(source)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONLines.append(try batch.map { try JSONLines.encoder.encode($0) }, to: folder.appendingPathComponent("\(month).\(host).jsonl"))
        }
    }

    /// With `sources`, only those sources' files are read.
    public func read(sources: Set<ArchiveSource>? = nil) throws -> LedgerContents {
        var contents = LedgerContents()
        var lines: [JSONLines.Line<LedgerEvent>] = []
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return contents }
        for name in try manager.contentsOfDirectory(atPath: directory.path).sorted() where !name.hasPrefix(".") {
            guard let source = ArchiveSource(rawValue: name) else {
                // A source folder named like ours belongs to a newer Lifelog; anything else is not ours.
                if Self.newerSource(name) { contents.newer.lines.append("ledger/\(name): source \(name)"); contents.newer.sources.insert(name) }
                else { contents.issues.append("ledger/\(name): unknown folder, ignored") }
                continue
            }
            if let sources, !sources.contains(source) { continue }
            let result = try JSONLines.read(LedgerEvent.self, in: directory.appendingPathComponent(name), label: "ledger/\(name)")
            contents.issues += result.issues
            contents.newer.lines += result.newer
            if !result.newer.isEmpty { contents.newer.sources.insert(name) }
            for line in result.lines {
                guard line.value.key.source == source else { contents.issues.append("\(line.location): event for \(line.value.key.source.rawValue) in \(name), ignored"); continue }
                lines.append(line)
            }
        }
        contents.events = JSONLines.merged(lines).map(\.value)
        return contents
    }

    /// Source folders are lowercase ASCII letters and digits, such as `claudecode`.
    static func newerSource(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }

    /// Ledger files with size and modification time, for cache validation.
    func stamps() -> [String: FileStamp] { JSONLines.stamps(in: directory) }
}

struct FileStamp: Codable, Equatable { var size: Int; var modified: Double }

/// Stable per-Mac id kept outside the synced folder, so two Macs never append to the same file.
public enum HostID {
    public static func current(directory: URL = defaultDirectory) throws -> String {
        let url = directory.appendingPathComponent("host-id")
        if let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), valid(value) { return value }
        let value = String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(12))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((value + "\n").utf8).write(to: url, options: .atomic)
        return value
    }

    public static func valid(_ value: String) -> Bool {
        (1...32).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.djui.lifelog")
    }
}

/// Shared JSONL plumbing for the ledger and the run log.
enum JSONLines {
    struct Line<Value> { var value: Value; var at: Date; var host: String; var file: String; var index: Int; var location: String }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer(); try c.encode(timestamp.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let value = try c.decode(String.self)
            guard let date = fastTimestamp(value) ?? timestamp.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date: \(value)")
            }
            return date
        }
        return decoder
    }()

    /// `YYYY-MM-DDTHH:MM:SS.fffZ`, the form `timestamp` writes, parsed without a formatter: loading an archive parses
    /// millions of these, and the formatter is many times slower. Anything else returns nil for the formatter to try.
    static func fastTimestamp(_ text: String) -> Date? {
        let utf8 = text.utf8
        guard utf8.count == 24 else { return nil }
        return utf8.withContiguousStorageIfAvailable { b -> Date? in
            guard b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A, b[19] == 0x2E, b[23] == 0x5A else { return nil }
            func number(_ from: Int, _ count: Int) -> Int? {
                var value = 0
                for index in from..<from + count {
                    let digit = Int(b[index]) - 0x30
                    guard (0...9).contains(digit) else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2), let hour = number(11, 2),
                  let minute = number(14, 2), let second = number(17, 2), let millisecond = number(20, 3),
                  (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
            // Days from civil (H. Hinnant), the inverse of `Partition.civil`.
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
            let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
            let seconds = days * 86_400 + hour * 3600 + minute * 60 + second
            return Date(timeIntervalSince1970: Double(seconds) + Double(millisecond) / 1000)
        } ?? nil
    }

    static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Values as a reader of the files will see them, such as dates cut to milliseconds.
    static func stored<Value: Codable>(_ values: [Value]) throws -> [Value] {
        try values.map { try decoder.decode(Value.self, from: encoder.encode($0)) }
    }

    static func month(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }

    /// `<YYYY-MM>.<host>.jsonl` → (month, host); anything else is not ours.
    static func parse(_ name: String) -> (month: String, host: String)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[2] == "jsonl", HostID.valid(parts[1]), parts[0].count == 7,
              parts[0].enumerated().allSatisfy({ $0.offset == 4 ? $0.element == "-" : $0.element.isASCII && $0.element.isNumber }) else { return nil }
        return (parts[0], parts[1])
    }

    /// Appends complete lines with O_APPEND and a full fsync. A torn tail left by an
    /// interrupted earlier write is cut off first, so torn lines only ever sit at the end.
    /// A file with no complete line is never cut: it is not a torn write of ours but a file
    /// still syncing or damaged, and cutting it would empty it.
    static func append(_ lines: [Data], to url: URL) throws {
        guard !lines.isEmpty else { return }
        let fd = Darwin.open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else { throw ExportError.message("Cannot open archive file: \(url.lastPathComponent)") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ExportError.message("Archive file is not a regular file: \(url.lastPathComponent)") }
        if info.st_size > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, info.st_size - 1) == 1 else { throw ExportError.message("Cannot read archive file: \(url.lastPathComponent)") }
            if last != 0x0A {
                var data = Data(count: Int(info.st_size))
                let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(info.st_size), 0) }
                guard count == Int(info.st_size) else { throw ExportError.message("Cannot read archive file: \(url.lastPathComponent)") }
                guard let newline = data.lastIndex(of: 0x0A) else { throw incomplete(url.lastPathComponent) }
                let keep = newline + 1
                guard ftruncate(fd, off_t(keep)) == 0 else { throw ExportError.message("Cannot repair archive file: \(url.lastPathComponent)") }
                ExportLog.info("dropped torn last line of \(url.lastPathComponent)")
            }
        }
        var payload = Data()
        for line in lines {
            precondition(!line.contains(0x0A), "JSONL lines must not contain newlines")
            payload.append(line); payload.append(0x0A)
        }
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, payload.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw ExportError.message("Cannot write archive file: \(url.lastPathComponent)") }
            offset += written
        }
        // F_FULLFSYNC reaches the disk platter; plain fsync is the fallback for file systems without it.
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw ExportError.message("Cannot sync archive file: \(url.lastPathComponent)") }
    }

    static func incomplete(_ file: String) -> ExportError {
        .message("Archive file has no complete line, so it may still be syncing or be damaged: \(file). Restore it, or move it aside, before the next run.")
    }

    /// Reads every host's month files in `folder`. An unterminated last line is torn and ignored,
    /// but a file with no complete line fails the read rather than reading as empty.
    /// Lines a newer Lifelog wrote (see `Versioned`) are left out and listed in `newer`, apart from damaged lines in `issues`.
    static func read<Value: Decodable & Timestamped & Versioned>(_ type: Value.Type, in folder: URL, label: String) throws -> (lines: [Line<Value>], issues: [String], newer: [String]) {
        var lines: [Line<Value>] = []
        var issues: [String] = []
        var newer: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where !name.hasPrefix(".") {
            guard let (_, host) = parse(name) else { issues.append("\(label)/\(name): unexpected file, ignored"); continue }
            let file = "\(label)/\(name)"
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            guard data.isEmpty || data.contains(0x0A) else { throw incomplete(file) }
            let read = parse(data, file: file, host: host, firstLine: 0, lines: &lines, issues: &issues, newer: &newer)
            if read.bytes < data.count { issues.append("\(file): ignored torn last line") }
        }
        return (lines, issues, newer)
    }

    /// The complete lines of `data`, a file's bytes from the start of line `firstLine` (0-based). Returns the bytes and
    /// lines up to the last newline; anything after it is torn, or still being written, and is left for a later read.
    @discardableResult
    static func parse<Value: Decodable & Timestamped & Versioned>(_ data: Data, file: String, host: String, firstLine: Int,
                                                                   lines: inout [Line<Value>], issues: inout [String], newer: inout [String]) -> (bytes: Int, count: Int) {
        guard let last = data.lastIndex(of: 0x0A) else { return (0, 0) }
        let complete = data[data.startIndex...last]
        let rows = complete.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
        for (offset, row) in rows.enumerated() where !row.isEmpty {
            let index = firstLine + offset
            let location = "\(file):\(index + 1)"
            let data = Data(row)
            // Probing only lines that fail to decode keeps the common path at one decode per line.
            if let value = try? decoder.decode(Value.self, from: data) {
                if value.v > Value.currentVersion { newer.append("\(location): format \(value.v)"); continue }
                lines.append(Line(value: value, at: value.at, host: host, file: file, index: index, location: location))
            } else if let reason = Value.newer(data) {
                newer.append("\(location): \(reason)")
            } else {
                issues.append("\(location): unreadable line, ignored")
            }
        }
        return (last - data.startIndex + 1, rows.count)
    }

    /// Timestamp order; ties keep host, then file and line order, so every Mac folds the same sequence.
    static func merged<Value>(_ lines: [Line<Value>]) -> [Line<Value>] {
        lines.sorted { ($0.at, $0.host, $0.file, $0.index) < ($1.at, $1.host, $1.file, $1.index) }
    }

    static func stamps(in folder: URL) -> [String: FileStamp] {
        var stamps: [String: FileStamp] = [:]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return stamps }
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            stamps[path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path] =
                FileStamp(size: values.fileSize ?? 0, modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return stamps
    }
}

protocol Timestamped { var at: Date { get } }
extension LedgerEvent: Timestamped {}
