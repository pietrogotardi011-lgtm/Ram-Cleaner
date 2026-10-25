import SwiftUI
import UserNotifications

struct ContentView: View {
    @AppStorage(Keys.intensity) private var intensity = Intensity.medium.rawValue
    @AppStorage(Keys.notify) private var notify = true
    @AppStorage(Keys.background) private var background = true
    @AppStorage(Keys.intervalMinutes) private var interval = 15
    @AppStorage(Keys.lastRun) private var lastRun: Double = 0
    @State private var status = ""
    @State private var footprint = Cleaner.footprint()
    @State private var available = Cleaner.available()
    private let fmt = ByteCountFormatter()

    var body: some View {
        NavigationStack {
            Form {
                Section("This app's memory") {
                    row("Footprint", fmt.string(fromByteCount: Int64(footprint)))
                    row("Available to app", fmt.string(fromByteCount: Int64(available)))
                    Button("Clean now") {
                        Task {
                            let r = await Cleaner.run(intensity: Intensity(rawValue: intensity) ?? .medium, notify: notify)
                            status = r.summary; refresh()
                        }
                    }
                    if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Intensity") {
                    Picker("Level", selection: $intensity) {
                        ForEach(Intensity.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented)
                    Text((Intensity(rawValue: intensity) ?? .medium).detail).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Notifications") {
                    Toggle("Show notification after cleaning", isOn: $notify)
                        .onChange(of: notify) { _, on in
                            if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                        }
                }
                Section("Background") {
                    Toggle("Background refresh", isOn: $background)
                    Stepper("Request every \(interval) min", value: $interval, in: 15...240, step: 15)
                    Text("iOS decides when background tasks actually run; the interval is only a minimum.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Shortcuts") {
                    Text("Open Shortcuts → add the \"Clean Memory\" action from RamTidy, then use it in a Personal Automation (time, charging, app open…).")
                        .font(.footnote)
                }
                if lastRun > 0 {
                    Section { row("Last run", Date(timeIntervalSince1970: lastRun).formatted()) }
                }
            }
            .navigationTitle("RamTidy")
            .onAppear { refresh() }
        }
    }
    private func row(_ a: String, _ b: String) -> some View { HStack { Text(a); Spacer(); Text(b).foregroundStyle(.secondary) } }
    private func refresh() { footprint = Cleaner.footprint(); available = Cleaner.available() }
}
