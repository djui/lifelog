import Foundation
import ICloudExporterCore
import Darwin

@main
struct ICloudExporter {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] || arguments == ["export", "--help"] {
            print(Config.help)
            return
        }
        if arguments == ["--version"] { print("icloud-exporter 0.1.0"); return }
        ExportLog.handler = { message in
            FileHandle.standardError.write(Data(("icloud-exporter: \(message)\n").utf8))
        }
        do {
            let config = try Config(arguments: arguments)
            let now = Date()
            let window = config.window(now: now)
            let selected = ExportSource.allCases.filter { config.sources.contains($0) }
            ExportLog.info("starting \(config.demo ? "demo" : "live") export of \(selected.map(\.rawValue).joined(separator: ", ")) to \(config.output.path)")
            let store = ExportStore(output: config.output)
            var summary = ExportSummary()
            var failures: [ExportSource: String] = [:]
            let demo = config.demo ? Demo.snapshot(now: now) : nil
            if demo != nil { ExportLog.info("using synthetic demo data") }
            let needsEventKit = demo == nil && (config.sources.contains(.reminders) || config.sources.contains(.calendar))
            let eventKit = needsEventKit ? EventKitExporter() : nil

            // Reminders and Calendar finish quickly; WhatsApp is a local SQLite copy; Notes can take minutes.
            for source in [ExportSource.reminders, .calendar, .whatsapp, .notes] where config.sources.contains(source) {
                do {
                    var snapshot = demo ?? ExportSnapshot()
                    if demo == nil {
                        snapshot = try await read(source, window: window, eventKit: eventKit, config: config, now: now)
                    }
                    var one = config
                    one.sources = [source]
                    ExportLog.info("rendering \(source.rawValue)")
                    let documents = try MarkdownWriter.documents(snapshot: snapshot, config: one, now: now)
                    summary.merge(try store.write(documents, sources: [source], now: now, demo: config.demo, warnings: snapshot.warnings))
                    for warning in snapshot.warnings[source] ?? [] { stderr("Warning (\(source.rawValue)): \(warning)") }
                } catch {
                    failures[source] = error.localizedDescription
                    stderr("Export failed (\(source.rawValue)): \(error.localizedDescription)")
                }
            }

            print("Export complete: \(summary.written) files written, \(summary.unchanged) unchanged, \(summary.removed) removed.")
            print("Output: \(config.output.path)")
            if !failures.isEmpty {
                let names = failures.keys.map(\.rawValue).sorted().joined(separator: ", ")
                stderr("Sources that did not export: \(names)")
                exit(1)
            }
        } catch {
            stderr("Export failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func read(_ source: ExportSource, window: (start: Date, end: Date, completedSince: Date), eventKit: EventKitExporter?, config: Config, now: Date) async throws -> ExportSnapshot {
        var snapshot = ExportSnapshot()
        switch source {
        case .notes:
            let result = try await NotesExporter.fetch()
            snapshot.notes = result.records
            snapshot.warnings[.notes] = result.warnings
        case .reminders:
            guard let eventKit else { throw ExportError.message("Reminders export is unavailable.") }
            let result = try await eventKit.reminders(completedSince: window.completedSince)
            snapshot.reminders = result.records
            snapshot.warnings[.reminders] = result.warnings
        case .calendar:
            guard let eventKit else { throw ExportError.message("Calendar export is unavailable.") }
            let result = try await eventKit.events(from: window.start, to: window.end)
            snapshot.events = result.records
            snapshot.warnings[.calendar] = result.warnings
        case .whatsapp:
            let result = try WhatsAppExporter.fetch(now: now, pastDays: config.pastDays, chatLimit: config.whatsappChats)
            snapshot.chats = result.records
            snapshot.warnings[.whatsapp] = result.warnings
        }
        return snapshot
    }

    static func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}
