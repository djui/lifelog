import Darwin
import Foundation

public enum NotesExportError: Error, LocalizedError {
    case missingScript
    case cannotStart
    case permissionDenied
    case timedOut
    case failed
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .missingScript: return "The bundled Notes exporter script is missing."
        case .cannotStart: return "The Notes exporter could not start."
        case .permissionDenied:
            return "Notes automation access was denied. Allow access in System Settings → Privacy & Security → Automation, then retry."
        case .timedOut: return "The Notes export timed out. A hidden Automation prompt or a large Notes library can cause this. No Notes snapshot was produced."
        case .failed: return "Notes could not be read completely. No Notes snapshot was produced."
        case .invalidOutput: return "Notes returned an invalid export. No Notes snapshot was produced."
        }
    }
}

public enum NotesExporter {
    static let resourceBundleName = "Lifelog_LifelogCore.bundle"

    static var scriptURL: URL? { resourceURL("notes.js") }

    /// A file in the resource bundle, also when the binary runs from the packaged app, where `Bundle.module` looks in the wrong place.
    static func resourceURL(_ path: String) -> URL? {
        let roots = [
            Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(resourceBundleName)"),
            Bundle.main.bundleURL.appendingPathComponent(resourceBundleName)
        ]
        // A bundle with a copied folder (`viewer/`) is a structured bundle with `Contents/Resources`; a flat one has none.
        for root in roots.compactMap({ $0 }) {
            for file in [root.appendingPathComponent("Contents/Resources/\(path)"), root.appendingPathComponent(path)] where FileManager.default.isReadableFile(atPath: file.path) {
                return file
            }
        }
        return Bundle.module.resourceURL.map { $0.appendingPathComponent(path) }.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil }
    }
    static let fetchTimeout: TimeInterval = 15 * 60

    /// `export` leaves `includeLocked` off; the archive keeps locked notes as body-less stubs.
    public static func fetch(includeLocked: Bool = false) async throws -> SourceResult<NoteRecord> {
        guard let script = scriptURL else {
            throw NotesExportError.missingScript
        }
        ExportLog.info("notes: starting osascript (may prompt for Automation; large libraries can take several minutes)")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try decode(run(script: script, timeout: fetchTimeout), includeLocked: includeLocked)
                    ExportLog.info("notes: read \(result.records.count) notes")
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Files avoid a pipe filling while osascript waits for its output to drain.
    // The private directory and files are removed on both success and failure.
    static func run(script: URL, timeout: TimeInterval) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifelog-notes-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw NotesExportError.cannotStart
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stdout")
        let snapshot = directory.appendingPathComponent("snapshot.json")
        for url in [output, snapshot] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw NotesExportError.cannotStart
            }
        }
        let stdout: FileHandle
        do {
            stdout = try FileHandle(forWritingTo: output)
        } catch {
            throw NotesExportError.cannotStart
        }
        defer { try? stdout.close() }

        let errPipe = Pipe()
        let progress = StderrProgress()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { progress.append(chunk) }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script.path, snapshot.path]
        process.standardOutput = stdout
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw NotesExportError.cannotStart
        }
        ExportLog.info("notes: osascript pid \(process.processIdentifier)")
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var finished = false
        while deadline.timeIntervalSinceNow > 0 {
            if completed.wait(timeout: .now() + min(15, deadline.timeIntervalSinceNow)) == .success {
                finished = true
                break
            }
            ExportLog.info("notes: still waiting on osascript (\(Int(Date().timeIntervalSince(started)))s elapsed)")
        }
        if !finished {
            ExportLog.info("notes: timed out after \(Int(timeout))s; stopping osascript")
            if process.isRunning { process.terminate() }
            if completed.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 2)
            }
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw NotesExportError.timedOut
        }
        errPipe.fileHandleForReading.readabilityHandler = nil
        progress.append(errPipe.fileHandleForReading.availableData)
        guard process.terminationStatus == 0 else {
            // Inspect only to classify the error; never surface raw stderr.
            let message = progress.message
            if message.contains("NOTES_AUTOMATION_DENIED") || message.contains("-1743") {
                throw NotesExportError.permissionDenied
            }
            throw NotesExportError.failed
        }
        do {
            if let data = try? Data(contentsOf: snapshot), !data.isEmpty { return data }
            return try Data(contentsOf: output)
        } catch {
            throw NotesExportError.invalidOutput
        }
    }

    static func decode(_ data: Data, includeLocked: Bool = false) throws -> SourceResult<NoteRecord> {
        struct Payload: Decodable {
            let records: [WireNote]
            let warnings: [String]
        }
        struct WireNote: Decodable {
            let id: String
            let title: String
            let account: String
            let folder: String
            let folderID: String?
            let created: String?
            let modified: String?
            let bodyHTML: String
            let locked: Bool?
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        func date(_ value: String?) throws -> Date? {
            guard let value else { return nil }
            guard let parsed = fractional.date(from: value) ?? standard.date(from: value) else {
                throw NotesExportError.invalidOutput
            }
            return parsed
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            var seen = Set<String>()
            let records = try payload.records.map { item in
                guard !item.id.isEmpty, seen.insert(item.id).inserted else {
                    throw NotesExportError.invalidOutput
                }
                return NoteRecord(id: item.id, title: item.title, account: item.account,
                                  folder: item.folder, created: try date(item.created),
                                  modified: try date(item.modified), bodyHTML: item.bodyHTML,
                                  isLocked: item.locked, folderID: item.folderID)
            }
            if includeLocked { return SourceResult(records: records, warnings: payload.warnings) }
            let unlocked = records.filter { $0.isLocked != true }
            var warnings = payload.warnings
            if unlocked.count < records.count {
                warnings.insert("\(records.count - unlocked.count) password-protected note(s) were skipped.", at: 0)
            }
            return SourceResult(records: unlocked, warnings: warnings)
        } catch {
            throw NotesExportError.invalidOutput
        }
    }
}

/// Forwards `NOTES_PROGRESS` lines to ExportLog and keeps stderr for error classification.
final class StderrProgress {
    private let lock = NSLock()
    private var collected = Data()
    private var leftover = ""

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        collected.append(data)
        leftover += String(data: data, encoding: .utf8) ?? ""
        while let range = leftover.range(of: "\n") {
            let line = leftover[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            leftover = String(leftover[range.upperBound...])
            if line.hasPrefix("NOTES_PROGRESS ") {
                lines.append(String(line.dropFirst("NOTES_PROGRESS ".count)))
            }
        }
        lock.unlock()
        for line in lines { ExportLog.info("notes: \(line)") }
    }

    var message: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: collected, encoding: .utf8) ?? ""
    }
}
