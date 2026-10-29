import AppKit
import Combine
import ICloudExporterCore
import ServiceManagement
import SwiftUI

/// The menu bar face of the app: archive runs on a schedule (`Scheduler`), their status, the viewer and the archive
/// folder, and Open at Login.
struct MenuBarApp: App {
    @StateObject private var model = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            Text(model.folder.map { "Archive: \($0.lastPathComponent)" } ?? "No archive folder chosen")
            ForEach(model.status, id: \.self) { Text($0) }
            if model.folder != nil, !model.started {
                Button("Start Archiving Here…") { model.startHere() }
            }
            Divider()
            Button("Run Now") { model.scheduler.runNow() }.keyboardShortcut("r")
                .disabled(model.folder == nil || model.scheduler.running != nil || !model.scheduler.agents.isEmpty)
            Menu("Pause") {
                Button("For 1 Hour") { model.scheduler.pause(for: 3600) }
                Button("For 8 Hours") { model.scheduler.pause(for: 8 * 3600) }
                Button("Resume") { model.scheduler.pause(for: nil) }.disabled(model.scheduler.pausedUntil == nil)
            }
            Button("Show Log") { NSWorkspace.shared.open(Runner.log) }.disabled(!FileManager.default.fileExists(atPath: Runner.log.path))
            Divider()
            Button("Open Viewer") { model.openViewer() }.keyboardShortcut("o")
            Button("Open Archive Folder") { model.openFolder() }.disabled(model.folder == nil)
            Button("Choose Archive Folder…") { model.chooseFolder() }
            Divider()
            Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            Divider()
            Button("Quit iCloud Exporter") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(nsImage: MenuBarIcon.image())
        }
    }
}

@MainActor
final class MenuModel: ObservableObject {
    static let folderKey = "archiveFolder"
    static let startedKey = "archiveStartedIn"

    @Published private(set) var folder: URL?
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    let defaults: UserDefaults
    let scheduler: Scheduler
    private var forward: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        scheduler = Scheduler(defaults: defaults)
        forward = scheduler.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        scheduler.start()
        if started { scheduler.folder = folder }
    }

    /// Archiving runs only in a folder that holds an archive already, or one the user confirmed, so choosing a busy
    /// folder (such as a whole Drive) never starts writing pages into it by surprise.
    var started: Bool {
        guard let folder else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(Ledger.folderName).path)
            || defaults.string(forKey: Self.startedKey) == folder.path
    }

    func startHere() {
        guard let folder else { return }
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Start archiving in \(folder.lastPathComponent)?"
        alert.informativeText = (items.isEmpty ? "The folder is empty. " : "The folder already holds \(items.count) item\(items.count == 1 ? "" : "s"); the archive adds _index.md, Notes/, WhatsApp/, Calendar/ and more next to them. An empty folder of its own is better. ")
            + "The first run reads your Notes, Reminders, Calendar and WhatsApp history, so macOS asks for access."
        alert.addButton(withTitle: "Start Archiving")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        defaults.set(folder.path, forKey: Self.startedKey)
        scheduler.folder = folder
        objectWillChange.send()
    }

    /// Status lines under the folder: what runs, what's next, and what went wrong.
    var status: [String] {
        let scheduler = scheduler
        guard folder != nil else { return ["Choose an archive folder to start archiving."] }
        guard started else { return ["No archive in this folder yet."] }
        if !scheduler.agents.isEmpty {
            return ["Runs come from launchd (\(scheduler.agents.count) archive agent\(scheduler.agents.count == 1 ? "" : "s")); remove them to let the app schedule."]
        }
        var lines: [String] = []
        if let lane = scheduler.running {
            lines.append("Archiving \(lane.sources.map(\.displayName).joined(separator: ", "))…")
        } else if let paused = scheduler.pausedUntil {
            lines.append("Paused until \(Self.time(paused))")
        } else {
            lines.append(scheduler.next.map { "Next run \(Self.time($0))" } ?? "Starting a run…")
        }
        for lane in Lane.all { lines.append("\(lane.name) (\(Int(lane.interval / 60)) min): " + (scheduler.lastRun[lane.id].map(Self.time) ?? "not run yet")) }
        if let problem = scheduler.problem { lines.append("Last run: \(problem)") }
        return lines
    }

    /// `14:31`, or `28 Oct, 14:31` when not today.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.day().month().hour().minute())
    }

    func openViewer() {
        guard let folder = folder ?? pickFolder() else { return }
        let page = folder.appendingPathComponent("_viewer/index.html")
        guard FileManager.default.fileExists(atPath: page.path) else {
            return alert("No viewer in \(folder.lastPathComponent)", "Run `icloud-exporter archive` or `rebuild` for this folder first; they write _viewer/index.html.")
        }
        NSWorkspace.shared.open(page)
    }

    func openFolder() {
        guard let folder else { return }
        NSWorkspace.shared.open(folder)
    }

    func chooseFolder() { _ = pickFolder() }

    /// Asks for the archive folder and remembers it. A folder without `.archive/` is kept too: the first run creates it.
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose the archive folder"
        panel.message = "The folder `icloud-exporter archive --output` writes to. It must not be an export folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { try Ledger.checkFolder(url) } catch {
            alert("This folder can't hold the archive", error.localizedDescription)
            return nil
        }
        defaults.set(url.path, forKey: Self.folderKey)
        folder = url
        scheduler.folder = started ? url : nil
        return url
    }

    func setOpensAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            alert("Could not change Open at Login", error.localizedDescription)
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        opensAtLogin = service.status == .enabled
    }

    func alert(_ title: String, _ message: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
