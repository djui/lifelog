import Foundation
import Darwin

public struct ExportSummary {
    public var written: Int = 0
    public var unchanged: Int = 0
    public var removed: Int = 0
}

/// Only files recorded in the manifest may be replaced or removed.
public final class ExportStore {
    struct Entry: Codable, Equatable { var source: String; var digest: String }
    struct Manifest: Codable, Equatable {
        var version = 1
        var mode: String
        var files: [String: Entry] = [:]
        var updated: [String: Date] = [:]
        var warnings: [String: [String]] = [:]
    }
    struct Pending: Codable { var committed: Manifest; var before: Manifest; var after: Manifest; var sources: Set<String> }
    public static let manifestName = ".icloud-exporter-manifest.json"
    static let pendingName = ".icloud-exporter-pending.json"
    let manager = FileManager.default
    let root: URL

    public init(output: URL) { root = output.resolvingSymlinksInPath().standardizedFileURL }

    public func write(_ documents: [ExportDocument], sources: Set<ExportSource>, now: Date, demo: Bool, warnings: [ExportSource: [String]]) throws -> ExportSummary {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let lockURL = try checked(".icloud-exporter.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ExportError.message("Cannot open export lock.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ExportError.message("Another export is using this output directory.") }
        defer { flock(fd, LOCK_UN) }

        let manifestURL = try checked(Self.manifestName)
        let pendingURL = try checked(Self.pendingName)
        let mode = demo ? "demo" : "live"
        let selected = Set(sources.map(\.rawValue))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var previous = Manifest(mode: mode)
        if manager.fileExists(atPath: manifestURL.path) {
            do { previous = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
            catch { throw ExportError.message("Export manifest cannot be read. Restore it before exporting again.") }
        }
        try validate(previous, mode: mode)
        let committed = previous
        if manager.fileExists(atPath: pendingURL.path) {
            let pending: Pending
            do { pending = try decoder.decode(Pending.self, from: Data(contentsOf: pendingURL)) }
            catch { throw ExportError.message("Export recovery journal cannot be read. Restore it or choose a new output directory.") }
            try validate(pending.before, mode: mode)
            try validate(pending.after, mode: mode)
            try validate(pending.committed, mode: mode)
            guard previous == pending.committed || previous == pending.after else { throw ExportError.message("Export manifest and recovery journal do not match.") }
            if previous != pending.after {
                guard selected.isSuperset(of: pending.sources) else { throw ExportError.message("An interrupted export needs recovery. Run again including these sources: \(pending.sources.sorted().joined(separator: ",")).") }
                for path in Set(pending.before.files.keys).union(pending.after.files.keys) {
                    let candidates = [pending.before.files[path], pending.after.files[path]].compactMap { $0 }
                    let url = try checked(path)
                    if manager.fileExists(atPath: url.path) {
                        let digest = MarkdownWriter.digest(try Data(contentsOf: url))
                        guard let entry = candidates.first(where: { $0.digest == digest }) else { throw ExportError.message("Export file was edited during recovery: \(path). Move it aside before retrying.") }
                        previous.files[path] = entry
                    } else {
                        previous.files[path] = candidates.first
                    }
                }
            }
        }
        guard Set(documents.map(\.path)).count == documents.count,
              documents.allSatisfy({ sources.contains($0.source) && $0.path.hasPrefix($0.source.rawValue.capitalized + "/") }) else {
            throw ExportError.message("Invalid export plan; document paths must be unique and belong to selected sources.")
        }
        var desired = Dictionary(uniqueKeysWithValues: documents.map { ($0.path, Data($0.content.utf8)) })
        var next = previous
        for (path, entry) in previous.files where selected.contains(entry.source) { next.files.removeValue(forKey: path) }
        for document in documents {
            next.files[document.path] = Entry(source: document.source.rawValue, digest: MarkdownWriter.digest(desired[document.path]!))
        }
        // Manifest dates have second precision so persisted journals compare exactly.
        let completedAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        for source in sources {
            next.updated[source.rawValue] = completedAt
            next.warnings[source.rawValue] = warnings[source] ?? []
        }
        desired["_index.md"] = Data(index(next).utf8)
        next.files["_index.md"] = Entry(source: "index", digest: MarkdownWriter.digest(desired["_index.md"]!))
        let removed = previous.files.keys.filter { next.files[$0] == nil }

        // Preflight every affected path before touching any existing export.
        for path in Set(desired.keys).union(removed) {
            try verifyOwnership(path, in: previous)
        }
        // Save both accepted versions before any mutation. A later run can resume
        // a mix of old/new files without treating exporter writes as manual edits.
        try encoder.encode(Pending(committed: committed, before: previous, after: next, sources: selected)).write(to: pendingURL, options: .atomic)
        var summary = ExportSummary()
        for path in desired.keys.sorted() {
            let url = try checked(path)
            let data = desired[path]!
            try verifyOwnership(path, in: previous)
            if let existing = try? Data(contentsOf: url), existing == data { summary.unchanged += 1; continue }
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            summary.written += 1
        }
        for path in removed.sorted() {
            let url = try checked(path)
            try verifyOwnership(path, in: previous)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url); summary.removed += 1 }
        }
        try encoder.encode(next).write(to: manifestURL, options: .atomic)
        try manager.removeItem(at: pendingURL)
        return summary
    }

    func verifyOwnership(_ path: String, in manifest: Manifest) throws {
        let url = try checked(path)
        if manager.fileExists(atPath: url.path) {
            guard let owned = manifest.files[path] else { throw ExportError.message("Refusing to overwrite an unmanaged file: \(path)") }
            guard MarkdownWriter.digest(try Data(contentsOf: url)) == owned.digest else { throw ExportError.message("Export file was edited outside the exporter: \(path). Move it aside before retrying.") }
        }
    }

    func validate(_ manifest: Manifest, mode: String) throws {
        guard manifest.version == 1, manifest.mode == mode else { throw ExportError.message("Output belongs to a different export version or demo/live mode. Choose a separate directory.") }
        for (path, entry) in manifest.files {
            let correctSource = entry.source == "index" ? path == "_index.md" :
                ExportSource(rawValue: entry.source).map { path.hasPrefix($0.rawValue.capitalized + "/") } == true
            guard correctSource, path.hasSuffix(".md"), entry.digest.count == 64,
                  entry.digest.allSatisfy({ $0.isHexDigit }) else { throw ExportError.message("Invalid managed file in export manifest.") }
            _ = try checked(path)
        }
    }

    func checked(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), !path.contains("\\"), !path.contains("\0") else {
            throw ExportError.message("Unsafe path in export manifest.")
        }
        var cursor = root
        for (index, part) in parts.enumerated() {
            cursor.appendPathComponent(String(part))
            if let attrs = try? manager.attributesOfItem(atPath: cursor.path) {
                let type = attrs[.type] as? FileAttributeType
                guard type != .typeSymbolicLink else { throw ExportError.message("Refusing symbolic link inside export directory: \(path)") }
                if index < parts.count - 1, type != .typeDirectory { throw ExportError.message("Export path has a non-directory parent: \(path)") }
                if index == parts.count - 1, type != .typeRegular { throw ExportError.message("Export path is not a regular file: \(path)") }
            }
        }
        return cursor
    }

    func index(_ manifest: Manifest) -> String {
        var lines = ["# iCloud Export", "", "Read-only snapshots of Apple data. Edit the original in its Apple app; exported files are managed by icloud-exporter.", ""]
        if manifest.mode == "demo" { lines += ["**Demo: synthetic examples only.**", ""] }
        for source in ExportSource.allCases {
            guard let updated = manifest.updated[source.rawValue] else { continue }
            lines += ["## \(source.rawValue.capitalized)", "", "Last successful export: \(MarkdownWriter.timestamp(updated))", ""]
            for path in manifest.files.keys.sorted() where manifest.files[path]?.source == source.rawValue {
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "?#[]()")
                let link = path.addingPercentEncoding(withAllowedCharacters: allowed)!
                lines.append("- [\(path.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]"))](\(link))")
            }
            lines.append("")
        }
        let warnings = ExportSource.allCases.flatMap { source in (manifest.warnings[source.rawValue] ?? []).map { "- \(source.rawValue.capitalized): " + $0 } }
        if !warnings.isEmpty { lines += ["## Export warnings", ""] + warnings + [""] }
        return lines.joined(separator: "\n") + "\n"
    }
}
