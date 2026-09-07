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
            let selected = ExportSource.allCases.filter { config.sources.contains($0) }.map(\.rawValue).joined(separator: ", ")
            ExportLog.info("starting \(config.demo ? "demo" : "live") export of \(selected) to \(config.output.path)")
            var snapshot = ExportSnapshot()
            if config.demo {
                ExportLog.info("using synthetic demo data")
                snapshot = Demo.snapshot(now: now)
            } else {
                let eventKit = EventKitExporter()
                if config.sources.contains(.notes) {
                    let result = try await NotesExporter.fetch()
                    snapshot.notes = result.records; snapshot.warnings[.notes] = result.warnings
                }
                if config.sources.contains(.reminders) {
                    let result = try await eventKit.reminders(completedSince: window.completedSince)
                    snapshot.reminders = result.records; snapshot.warnings[.reminders] = result.warnings
                }
                if config.sources.contains(.calendar) {
                    let result = try await eventKit.events(from: window.start, to: window.end)
                    snapshot.events = result.records; snapshot.warnings[.calendar] = result.warnings
                }
            }
            // Complete all source reads before changing the managed snapshot.
            ExportLog.info("rendering markdown for \(config.sources.contains(.notes) ? snapshot.notes.count : 0) notes, \(config.sources.contains(.reminders) ? snapshot.reminders.count : 0) reminders, \(config.sources.contains(.calendar) ? snapshot.events.count : 0) events")
            let documents = try MarkdownWriter.documents(snapshot: snapshot, config: config, now: now)
            let summary = try ExportStore(output: config.output).write(documents, sources: config.sources, now: now, demo: config.demo, warnings: snapshot.warnings)
            print("Export complete: \(summary.written) files written, \(summary.unchanged) unchanged, \(summary.removed) removed.")
            print("Output: \(config.output.path)")
            for source in ExportSource.allCases {
                for warning in snapshot.warnings[source] ?? [] { stderr("Warning (\(source.rawValue)): \(warning)") }
            }
        } catch {
            stderr("Export failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}
