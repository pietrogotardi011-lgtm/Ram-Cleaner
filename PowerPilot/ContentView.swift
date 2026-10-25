import SwiftUI
import Charts

private let thermalColors: [Color] = [.green, .yellow, .orange, .red]

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var phase
    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Status", systemImage: "gauge.with.needle") }
            HistoryView().tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            SettingsView().tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            ShortcutsHelpView().tabItem { Label("Shortcuts", systemImage: "square.stack.3d.up") }
        }
        .onAppear { if Prefs.notify { Notifier.requestAuth() } }
    }
}

struct DashboardView: View {
    @Environment(\.scenePhase) private var phase
    @State private var snap = Snapshot.placeholder
    @State private var result = ""
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var ringColor: Color {
        if snap.level < 0 { return .gray }
        if snap.charging { return .green }
        if snap.level <= Prefs.lowLevel { return .red }
        return .blue
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Color.gray.opacity(0.2), lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: CGFloat(max(snap.level, 0)) / 100)
                            .stroke(ringColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text(snap.levelText).font(.system(size: 44, weight: .bold, design: .rounded))
                            Text(snap.full ? "Full" : (snap.charging ? "Charging" : "On battery"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 190, height: 190)
                    .padding(.top, 8)

                    HStack(spacing: 12) {
                        Card {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Thermal", systemImage: "thermometer.medium").font(.caption).foregroundStyle(.secondary)
                                Text(snap.thermalName).font(.title3.bold()).foregroundStyle(thermalColors[min(snap.thermal, 3)])
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Low Power", systemImage: "bolt.fill").font(.caption).foregroundStyle(.secondary)
                                Text(snap.lowPower ? "On" : "Off").font(.title3.bold())
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tips").font(.headline)
                            ForEach(Advice.tips(for: snap)) { tip in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: tip.icon)
                                        .foregroundStyle(tip.severity == 2 ? Color.red : (tip.severity == 1 ? Color.orange : Color.green))
                                        .frame(width: 24)
                                    Text(tip.text).font(.subheadline)
                                }
                            }
                        }
                    }

                    Button {
                        Task { @MainActor in
                            let s = Monitor.snapshot()
                            snap = s
                            Store.append(s)
                            let msgs = await Notifier.evaluate(s)
                            result = msgs.isEmpty ? "All clear." : msgs.joined(separator: "\n")
                        }
                    } label: {
                        Label("Check and alert now", systemImage: "bell.badge").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if !result.isEmpty { Text(result).font(.footnote).foregroundStyle(.secondary) }
                }
                .padding()
            }
            .navigationTitle("PowerPilot")
            .onAppear { reload(log: true) }
            .onChange(of: phase) { _, p in if p == .active { reload(log: true) } }
            .onReceive(timer) { _ in Task { @MainActor in reload(log: false) } }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                Task { @MainActor in reload(log: true) }
            }
        }
    }

    @MainActor private func reload(log: Bool) {
        let s = Monitor.snapshot()
        snap = s
        if log && Prefs.autoLog { Store.append(s) }
    }
}

struct HistoryView: View {
    @State private var history: [Snapshot] = []

    var body: some View {
        NavigationStack {
            List {
                if history.count < 2 {
                    Text("Not enough data yet. Open the app a few times or enable auto-logging in Settings.")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Battery %") {
                        Chart(history.filter { $0.level >= 0 }) { s in
                            LineMark(x: .value("Time", s.date), y: .value("Battery", s.level))
                        }
                        .chartYScale(domain: 0...100)
                        .frame(height: 180)
                    }
                    Section("Thermal state (0 nominal – 3 critical)") {
                        Chart(history) { s in
                            BarMark(x: .value("Time", s.date), y: .value("Thermal", s.thermal))
                                .foregroundStyle(thermalColors[min(s.thermal, 3)])
                        }
                        .chartYScale(domain: 0...3)
                        .chartYAxis { AxisMarks(values: [0, 1, 2, 3]) }
                        .frame(height: 140)
                    }
                    Section("Latest entries") {
                        ForEach(history.suffix(15).reversed()) { s in
                            HStack {
                                Text(s.date.formatted(date: .omitted, time: .shortened))
                                Spacer()
                                Text("\(s.levelText) · \(s.thermalName)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Clear history", role: .destructive) { Store.clear(); history = [] }
                }
            }
            .navigationTitle("History")
            .onAppear { history = Store.load() }
        }
    }
}

struct SettingsView: View {
    @AppStorage(Keys.notify) private var notify = true
    @AppStorage(Keys.notifyHot) private var notifyHot = true
    @AppStorage(Keys.notifyCharge) private var notifyCharge = true
    @AppStorage(Keys.notifyLow) private var notifyLow = true
    @AppStorage(Keys.chargeLimit) private var chargeLimit = 80
    @AppStorage(Keys.lowLevel) private var lowLevel = 20
    @AppStorage(Keys.hotThreshold) private var hotThreshold = 2
    @AppStorage(Keys.autoLog) private var autoLog = true
    @AppStorage(Keys.intervalMinutes) private var interval = 15
    @AppStorage(Keys.appearance) private var appearance = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Toggle("Enable notifications", isOn: $notify)
                        .onChange(of: notify) { _, on in if on { Notifier.requestAuth() } }
                    Toggle("Phone is hot", isOn: $notifyHot).disabled(!notify)
                    Toggle("Charge limit reached", isOn: $notifyCharge).disabled(!notify)
                    Toggle("Battery low", isOn: $notifyLow).disabled(!notify)
                    Text("Each alert repeats at most every 30 minutes.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Thresholds") {
                    Stepper("Charge limit: \(chargeLimit)%", value: $chargeLimit, in: 50...100, step: 5)
                    Stepper("Low battery: \(lowLevel)%", value: $lowLevel, in: 5...50, step: 5)
                    Picker("Hot alert from", selection: $hotThreshold) {
                        Text("Fair").tag(1)
                        Text("Serious").tag(2)
                        Text("Critical").tag(3)
                    }
                }
                Section("Background") {
                    Toggle("Auto-log history", isOn: $autoLog)
                    Stepper("Request every \(interval) min", value: $interval, in: 15...240, step: 15)
                    Text("iOS decides when background checks actually run. For reliable checks, trigger the Check and Alert action from a Shortcuts automation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }.pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct ShortcutsHelpView: View {
    private let actions: [(String, String)] = [
        ("Get Battery Status", "Text summary of everything"),
        ("Get Battery Level", "Number, e.g. 72"),
        ("Get Thermal State", "Nominal / Fair / Serious / Critical"),
        ("Is Phone Hot?", "Yes/No (optional: include Fair)"),
        ("Is Charging?", "Yes/No"),
        ("Is Low Power Mode On?", "Yes/No"),
        ("Is Battery Below?", "Yes/No for a percentage you choose"),
        ("Should I Unplug?", "Yes/No based on your charge limit"),
        ("Get Power Tips", "Text tips for right now"),
        ("Get Battery Trend", "Drain or charge rate over 3 hours"),
        ("Check and Alert", "Runs checks, sends notifications, returns findings"),
        ("Log Battery Snapshot", "Adds a point to History"),
        ("Apply Power Profile", "Returns steps for Max Battery, Cool Down, Performance or Overnight")
    ]
    private let recipes: [(String, String)] = [
        ("Cool down automatically", "Automation: Time of Day every 15 min (or When charging starts) → Is Phone Hot? → If Yes → Set Low Power Mode On, Set Brightness 20%, Set Bluetooth Off."),
        ("Protect the battery", "Automation: When charging starts → Should I Unplug? → If Yes → Show Notification, or use Check and Alert."),
        ("Auto power saver", "Automation: Battery Level falls below 30% → Apply Power Profile (Max Battery) → Set Low Power Mode On, Set Brightness 30%."),
        ("Overnight", "Automation: Time 23:00 → Apply Power Profile (Overnight) → Set Low Power Mode On, Set Brightness 0%.")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Open Shortcuts app") {
                        if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
                    }
                    Text("PowerPilot reads the phone's real state. Apple's own Shortcuts actions (Low Power Mode, Brightness, Bluetooth…) make the changes. In Personal Automations, choose Run Immediately so they do not ask each time.")
                        .font(.footnote)
                }
                Section("Actions") {
                    ForEach(actions, id: \.0) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.0).font(.headline)
                            Text(a.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Recipes") {
                    ForEach(recipes, id: \.0) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.0).font(.headline)
                            Text(r.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Shortcuts")
        }
    }
}
