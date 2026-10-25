import SwiftUI
import BackgroundTasks
import UserNotifications

final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

let refreshID = "com.example.powerpilot.refresh"

func scheduleRefresh() {
    guard Prefs.autoLog || Prefs.notify else { return }
    let req = BGAppRefreshTaskRequest(identifier: refreshID)
    req.earliestBeginDate = Date(timeIntervalSinceNow: Double(Prefs.intervalMinutes) * 60)
    try? BGTaskScheduler.shared.submit(req)
}

func runBackgroundCheck() async {
    let s = await Monitor.snapshot()
    if Prefs.autoLog { Store.append(s) }
    _ = await Notifier.evaluate(s)
}

@main
struct PowerPilotApp: App {
    @AppStorage(Keys.appearance) private var appearance = "system"
    @Environment(\.scenePhase) private var phase

    init() { UNUserNotificationCenter.current().delegate = NotifDelegate.shared }

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(scheme)
        }
        .onChange(of: phase) { _, p in
            if p == .background { scheduleRefresh() }
        }
        .backgroundTask(.appRefresh(refreshID)) {
            scheduleRefresh()
            await runBackgroundCheck()
        }
    }
}
