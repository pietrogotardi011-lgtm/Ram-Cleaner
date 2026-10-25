import SwiftUI
import BackgroundTasks

let refreshID = "com.example.ramtidy.refresh"

func scheduleRefresh() {
    guard Prefs.background else { return }
    let req = BGAppRefreshTaskRequest(identifier: refreshID)
    req.earliestBeginDate = Date(timeIntervalSinceNow: Double(Prefs.intervalMinutes) * 60)
    try? BGTaskScheduler.shared.submit(req)
}

@main
struct RamTidyApp: App {
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup { ContentView() }
            .onChange(of: phase) { _, p in if p == .background { scheduleRefresh() } }
            .backgroundTask(.appRefresh(refreshID)) {
                scheduleRefresh()
                await Cleaner.run(intensity: Prefs.intensity, notify: Prefs.notify)
            }
    }
}
