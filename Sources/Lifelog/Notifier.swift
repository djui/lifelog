import Foundation
import LifelogCore
import UserNotifications

/// Posts health notices as macOS notifications (decision 17), each notice id once. From the signed `.app`
/// it uses UserNotifications under the app's identity; a bare binary (`swift run`) has no bundle for that,
/// so it falls back to `osascript`.
@MainActor
enum Notifier {
    /// `sentFile` lives in the archive's cache folder. A notice that could not be posted is tried again next run.
    static func send(_ notices: [HealthNotice], sentFile: URL, now: Date) async {
        var sent = SentNotices.load(sentFile)
        let pending = sent.unsent(notices)
        guard !pending.isEmpty else { return }
        for notice in pending where await post(notice) { sent.mark(notice.id, at: now) }
        do { try sent.save(sentFile) } catch { Lifelog.stderr("Warning: could not remember sent notifications: \(error.localizedDescription)") }
    }

    static func post(_ notice: HealthNotice) async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return osascript(notice) }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                Lifelog.stderr("Warning: notifications are turned off for Lifelog in System Settings › Notifications.")
                return false
            }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
            return true
        } catch {
            Lifelog.stderr("Warning: could not post a notification: \(error.localizedDescription)")
            return false
        }
    }

    /// Title and body go in as arguments, never into the script text.
    static func osascript(_ notice: HealthNotice) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run", notice.title, notice.body]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Lifelog.stderr("Warning: could not post a notification: \(error.localizedDescription)")
            return false
        }
    }
}
