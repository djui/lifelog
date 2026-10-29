import Foundation

public struct ExportSummary {
    public var written: Int = 0
    public var unchanged: Int = 0
    public var removed: Int = 0

    public init(written: Int = 0, unchanged: Int = 0, removed: Int = 0) {
        self.written = written
        self.unchanged = unchanged
        self.removed = removed
    }

    public mutating func merge(_ other: ExportSummary) {
        written += other.written
        unchanged += other.unchanged
        removed += other.removed
    }
}

/// Only files recorded in the manifest may be replaced or removed. `export` mirrors sources into one folder;
/// the archive keeps its pages (views of the ledger) in another layout with its own manifest under `.archive/`.
public final class ExportStore {
    /// `group` is a source (`notes`) or another top-level page group (`timeline`, `disappeared`, `index`, `viewer`).
    struct Entry: Codable, Equatable {
        var group: String; var digest: String
        enum CodingKeys: String, CodingKey { case group = "source", digest }
        init(group: String, digest: String) { self.group = group; self.digest = digest }
        init(source: String, digest: String) { self.init(group: source, digest: digest) }
    }
    struct Manifest: Codable, Equatable {
        var version = 1
        var mode: String
        var files: [String: Entry] = [:]
        var updated: [String: Date] = [:]
        var warnings: [String: [String]] = [:]
    }
    struct Pending: Codable { var committed: Manifest; var before: Manifest; var after: Manifest; var sources: Set<String> }

    public enum Layout { case export, archive }

    public static let manifestName = ".icloud-exporter-manifest.json"
    static let pendingName = ".icloud-exporter-pending.json"
    static let pagesManifestName = Ledger.folderName + "/pages.json"
    static let pagesPendingName = Ledger.folderName + "/pages-pending.json"
    let manager = FileManager.default
    let root: URL
    let layout: Layout

    public init(output: URL, layout: Layout = .export) {
        root = output.resolvingSymlinksInPath().standardizedFileURL
        self.layout = layout
    }

    var manifestPath: String { layout == .export ? Self.manifestName : Self.pagesManifestName }
    var pendingPath: String { layout == .export ? Self.pendingName : Self.pagesPendingName }

    /// Top-level directory of a page group; nil for `index`, which owns only `_index.md`.
    static func directory(of group: String) -> String? {
        switch group {
        case "timeline": return "Timeline"
        case "disappeared": return "_Disappeared"
        default: return ExportSource(rawValue: group)?.directoryName
        }
    }

    func allows(_ group: String, path: String) -> Bool {
        if group == "index" { return path == "_index.md" }
        // The HTML viewer: its static app, data scripts and styles.
        if group == ViewerData.group {
            return layout == .archive && path.hasPrefix(ViewerData.folder + "/") && [".html", ".js", ".css"].contains { path.hasSuffix($0) }
        }
        guard let directory = Self.directory(of: group), path.hasPrefix(directory + "/") else { return false }
        return layout == .archive || ExportSource.exportable.contains { $0.rawValue == group }
    }

    public func write(_ documents: [ExportDocument], sources: Set<ExportSource>, now: Date, demo: Bool, warnings: [ExportSource: [String]]) throws -> ExportSummary {
        precondition(layout == .export)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try ArchiveLock(try checked(ArchiveLock.name), owner: "export")
        defer { lock.release() }
        guard !manager.fileExists(atPath: root.appendingPathComponent(Ledger.folderName).path) else {
            throw ExportError.message("Output folder holds a lifelong archive (\(Ledger.folderName)/). Choose a separate folder for the export.")
        }
        guard documents.allSatisfy({ $0.source.map(sources.contains) == true }) else {
            throw ExportError.message("Invalid export plan; document paths must be unique and belong to selected sources.")
        }
        let selected = Set(sources.map(\.rawValue))
        return try commit(documents, mode: demo ? "demo" : "live", groups: selected) { next, desired in
            // Manifest dates have second precision so persisted journals compare exactly.
            let completedAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
            for source in sources {
                next.updated[source.rawValue] = completedAt
                next.warnings[source.rawValue] = warnings[source] ?? []
            }
            desired["_index.md"] = Data(self.index(next).utf8)
            next.files["_index.md"] = Entry(group: "index", digest: MarkdownWriter.digest(desired["_index.md"]!))
        }
    }

    /// Paths the archive manifest owns now. Empty while an interrupted write awaits recovery, so the caller renders everything.
    public func managedPaths() throws -> Set<String> {
        guard !manager.fileExists(atPath: try checked(pendingPath).path) else { return [] }
        let url = try checked(manifestPath)
        guard let data = try? Data(contentsOf: url), let manifest = try? Self.decoder.decode(Manifest.self, from: data) else { return [] }
        return Set(manifest.files.keys)
    }

    /// Writes archive pages: `documents` are rendered now, `keeping` are pages still wanted as they are, and every other
    /// managed page is removed. Only changed files are rewritten. The caller holds the `ArchiveLock`.
    public func writePages(_ documents: [ExportDocument], keeping: Set<String>, demo: Bool) throws -> ExportSummary {
        precondition(layout == .archive)
        try manager.createDirectory(at: root.appendingPathComponent(Ledger.folderName), withIntermediateDirectories: true)
        return try commit(documents, mode: demo ? "demo" : "live", groups: nil) { next, _ in
            let lost = keeping.filter { next.files[$0] == nil }
            guard lost.isEmpty else { throw ExportError.message("Archive pages manifest changed during the run: \(lost.sorted().first!). Run rebuild.") }
            let rendered = Set(documents.map(\.path))
            next.files = next.files.filter { keeping.contains($0.key) || rendered.contains($0.key) }
        } adopt: { previous in
            // Phase 4 wrote `_index.md` without a manifest; adopt that page once.
            let index = try self.checked("_index.md")
            if previous.files.isEmpty, let data = try? Data(contentsOf: index), data.starts(with: Data("# Archive\n".utf8)) {
                previous.files["_index.md"] = Entry(group: "index", digest: MarkdownWriter.digest(data))
            }
        }
    }

    static let decoder: JSONDecoder = { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }()

    /// The manifest and journal discipline shared by both layouts. `groups` names the groups whose old entries are
    /// replaced (nil: the plan decides); `plan` finishes the next manifest and may add generated files.
    func commit(_ documents: [ExportDocument], mode: String, groups selected: Set<String>?, plan: (inout Manifest, inout [String: Data]) throws -> Void,
                adopt: ((inout Manifest) throws -> Void)? = nil) throws -> ExportSummary {
        let manifestURL = try checked(manifestPath)
        let pendingURL = try checked(pendingPath)
        let decoder = Self.decoder
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var previous = Manifest(mode: mode)
        if manager.fileExists(atPath: manifestURL.path) {
            do { previous = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
            catch { throw ExportError.message("Export manifest cannot be read. Restore it before exporting again.") }
        } else {
            try adopt?(&previous)
        }
        try validate(previous, mode: mode)
        let committed = previous
        if manager.fileExists(atPath: pendingURL.path) {
            ExportLog.info("recovering interrupted export in \(root.path)")
            let pending: Pending
            do { pending = try decoder.decode(Pending.self, from: Data(contentsOf: pendingURL)) }
            catch { throw ExportError.message("Export recovery journal cannot be read. Restore it or choose a new output directory.") }
            try validate(pending.before, mode: mode)
            try validate(pending.after, mode: mode)
            try validate(pending.committed, mode: mode)
            guard previous == pending.committed || previous == pending.after else { throw ExportError.message("Export manifest and recovery journal do not match.") }
            if previous != pending.after {
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
        guard Set(documents.map(\.path)).count == documents.count, documents.allSatisfy({ allows($0.group, path: $0.path) }) else {
            throw ExportError.message("Invalid export plan; document paths must be unique and belong to selected sources.")
        }
        var desired = Dictionary(uniqueKeysWithValues: documents.map { ($0.path, Data($0.content.utf8)) })
        var next = previous
        if let selected {
            for (path, entry) in previous.files where selected.contains(entry.group) { next.files.removeValue(forKey: path) }
        }
        for document in documents {
            next.files[document.path] = Entry(group: document.group, digest: MarkdownWriter.digest(desired[document.path]!))
        }
        try plan(&next, &desired)
        let removed = previous.files.keys.filter { next.files[$0] == nil }

        // Preflight every affected path before touching any existing export.
        for path in Set(desired.keys).union(removed) {
            try verifyOwnership(path, in: previous)
        }
        // Save both accepted versions before any mutation. A later run can resume
        // a mix of old/new files without treating exporter writes as manual edits.
        try encoder.encode(Pending(committed: committed, before: previous, after: next, sources: selected ?? Set(next.files.values.map(\.group)))).write(to: pendingURL, options: .atomic)
        ExportLog.info("writing \(desired.count) files to \(root.path)\(removed.isEmpty ? "" : ", removing \(removed.count) stale")")
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
            guard allows(entry.group, path: path), path.hasSuffix(".md") || entry.group == ViewerData.group, entry.digest.count == 64,
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
        var lines = ["# iCloud Export", "", "Read-only snapshots of Notes, Reminders, Calendar, and WhatsApp. Edit the original in its app; exported files are managed by lifelog.", ""]
        if manifest.mode == "demo" { lines += ["**Demo: synthetic examples only.**", ""] }
        for source in ExportSource.allCases {
            guard let updated = manifest.updated[source.rawValue] else { continue }
            lines += ["## \(source.displayName)", "", "Last successful export: \(MarkdownWriter.timestamp(updated))", ""]
            for path in manifest.files.keys.sorted() where manifest.files[path]?.group == source.rawValue {
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "?#[]()")
                let link = path.addingPercentEncoding(withAllowedCharacters: allowed)!
                lines.append("- [\(path.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]"))](\(link))")
            }
            lines.append("")
        }
        let warnings = ExportSource.allCases.flatMap { source in (manifest.warnings[source.rawValue] ?? []).map { "- \(source.displayName): " + $0 } }
        if !warnings.isEmpty { lines += ["## Export warnings", ""] + warnings + [""] }
        return lines.joined(separator: "\n") + "\n"
    }
}
