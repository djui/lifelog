import AppKit
import ICloudExporterCore
import ServiceManagement
import SwiftUI

/// The menu bar face of the app (menu bar plan, PR 1): open the viewer and the archive folder, choose the folder,
/// open at login. Archive runs still come from the CLI and launchd until the scheduler lands.
struct MenuBarApp: App {
    @StateObject private var model = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            Text(model.folder.map { "Archive: \($0.lastPathComponent)" } ?? "No archive folder chosen")
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

    @Published private(set) var folder: URL?
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
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
