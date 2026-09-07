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
        case .timedOut: return "The Notes export timed out. No Notes snapshot was produced."
        case .failed: return "Notes could not be read completely. No Notes snapshot was produced."
        case .invalidOutput: return "Notes returned an invalid export. No Notes snapshot was produced."
        }
    }
}

public enum NotesExporter {
    static var scriptURL: URL? { Bundle.module.url(forResource: "notes", withExtension: "js") }

    public static func fetch() async throws -> SourceResult<NoteRecord> {
        guard let script = scriptURL else {
            throw NotesExportError.missingScript
        }
        ExportLog.info("notes: starting osascript (may prompt for Automation; up to 180s)")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try decode(run(script: script, timeout: 180))
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
            .appendingPathComponent("icloud-exporter-notes-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw NotesExportError.cannotStart
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stdout")
        let errorOutput = directory.appendingPathComponent("stderr")
        for url in [output, errorOutput] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw NotesExportError.cannotStart
            }
        }
        let stdout: FileHandle
        let stderr: FileHandle
        do {
            stdout = try FileHandle(forWritingTo: output)
            stderr = try FileHandle(forWritingTo: errorOutput)
        } catch {
            throw NotesExportError.cannotStart
        }
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script.path]
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
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
            throw NotesExportError.timedOut
        }
        guard process.terminationStatus == 0 else {
            // Inspect only to classify the error; never surface raw stderr.
            let message = (try? String(contentsOf: errorOutput, encoding: .utf8)) ?? ""
            if message.contains("NOTES_AUTOMATION_DENIED") || message.contains("-1743") {
                throw NotesExportError.permissionDenied
            }
            throw NotesExportError.failed
        }
        do {
            return try Data(contentsOf: output)
        } catch {
            throw NotesExportError.invalidOutput
        }
    }

    static func decode(_ data: Data) throws -> SourceResult<NoteRecord> {
        struct Payload: Decodable {
            let records: [WireNote]
            let warnings: [String]
        }
        struct WireNote: Decodable {
            let id: String
            let title: String
            let account: String
            let folder: String
            let created: String?
            let modified: String?
            let bodyHTML: String
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
                                  modified: try date(item.modified), bodyHTML: item.bodyHTML)
            }
            return SourceResult(records: records, warnings: payload.warnings)
        } catch {
            throw NotesExportError.invalidOutput
        }
    }
}
