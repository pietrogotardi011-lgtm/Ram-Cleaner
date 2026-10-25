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
            ProfilesView().tabItem { Label("Profiles", systemImage: "bolt.circle") }
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
                            let msgs = await Notifier.evaluate(s, force: true)
                            var text = msgs.isEmpty ? "All clear. No alert conditions right now." : msgs.joined(separator: "\n")
                            if !msgs.isEmpty {
                                let st = await Notifier.status()
                                if !Prefs.notify { text += "\n(Notifications are turned off in PowerPilot settings.)" }
                                else if st != .authorized { text += "\n(iOS notifications are \(Notifier.statusText(st)). Enable them in Settings → Notifications → PowerPilot.)" }
                            }
                            result = text
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
    @State private var authText = "Checking…"
    @State private var testMsg = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Notification status") {
                    HStack { Text("iOS permission"); Spacer(); Text(authText).foregroundStyle(.secondary) }
                    Button("Send test notification (in 5 s)") {
                        Task {
                            let ok = await Notifier.post(title: "PowerPilot test", body: "If you can read this, notifications work.", delay: 5)
                            testMsg = ok ? "Sent. It arrives in 5 seconds; you can lock the phone." : "Could not send. Allow notifications for PowerPilot in iOS Settings."
                            authText = Notifier.statusText(await Notifier.status())
                        }
                    }
                    Button("Open iOS notification settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    if !testMsg.isEmpty { Text(testMsg).font(.footnote).foregroundStyle(.secondary) }
                }
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
            .task { authText = Notifier.statusText(await Notifier.status()) }
        }
    }
}

struct ProfilesView: View {
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Apply sets the screen brightness right now and runs the matching PowerPilot shortcut, which switches Low Power Mode, Bluetooth and Wi-Fi. Install the shortcuts from the Shortcuts tab first.")
                        .font(.footnote)
                }
                ForEach(PowerProfileOption.allCases, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(p.title).font(.headline)
                        Text(p.detail).font(.footnote).foregroundStyle(.secondary)
                        Button("Apply \(p.title)") { apply(p) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
                if !message.isEmpty { Section { Text(message).font(.footnote) } }
            }
            .navigationTitle("Profiles")
        }
    }

    private func apply(_ p: PowerProfileOption) {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            scene.screen.brightness = CGFloat(p.brightness)
        }
        message = "Brightness set to \(Int(p.brightness * 100))%. Running \"\(p.shortcutName)\"…"
        let info = ShortcutInfo(name: p.shortcutName, summary: "")
        if let url = info.runURL { UIApplication.shared.open(url) }
    }
}

struct ShortcutsHelpView: View {
    @Environment(\.openURL) private var openURL

    private let recipes: [(String, String)] = [
        ("Low battery → saver", "Shortcuts → Automation → + → Battery Level → Falls Below 30% → Run Immediately → Run Shortcut: PowerPilot Max Battery."),
        ("Charged enough → unplug alert", "Automation → Battery Level → Rises Above 80% → Run Immediately → Run Shortcut: PowerPilot Unplug Alert."),
        ("Bedtime", "Automation → Time of Day 23:00 → Run Immediately → Run Shortcut: PowerPilot Overnight. Add 07:00 → PowerPilot Normal."),
        ("Back to normal on charger", "Automation → Charger → Is Connected → Run Immediately → Run Shortcut: PowerPilot Normal, then PowerPilot Log."),
        ("Heat watch while gaming", "Automation → App → Is Opened → pick your game or Camera → Run Immediately → Run Shortcut: PowerPilot Heat Check.")
    ]
    private let intentActions: [(String, String)] = [
        ("Get Battery Status", "Text summary"),
        ("Get Battery Level", "Number, e.g. 72"),
        ("Get Thermal State", "Nominal / Fair / Serious / Critical"),
        ("Is Phone Hot?", "Yes/No"),
        ("Is Charging?", "Yes/No"),
        ("Is Low Power Mode On?", "Yes/No"),
        ("Is Battery Below?", "Yes/No for a percentage"),
        ("Should I Unplug?", "Yes/No from your charge limit"),
        ("Get Power Tips", "Text tips"),
        ("Get Battery Trend", "Rate over 3 hours"),
        ("Check and Alert", "Checks, notifies, returns findings"),
        ("Log Battery Snapshot", "Adds a point to History"),
        ("Apply Power Profile", "Returns profile steps")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("1. Install the shortcuts") {
                    ForEach(ShortcutLinks.all) { sc in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(sc.name).font(.headline)
                            Text(sc.summary).font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                Button(sc.link.isEmpty ? "Link not added yet" : "Install") {
                                    if let u = URL(string: sc.link) { openURL(u) }
                                }
                                .buttonStyle(.bordered).disabled(sc.link.isEmpty)
                                Button("Run") { if let u = sc.runURL { openURL(u) } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    Text("The Heat Check and Log shortcuts use PowerPilot's own actions. If one shows a missing action, open it in Shortcuts and re-add the action from PowerPilot.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("2. Create the automations") {
                    Text("iOS does not allow automations to be shared, so create each one once. Choose Run Immediately so it never asks.")
                        .font(.footnote)
                    Button("Open Shortcuts app") { if let u = URL(string: "shortcuts://") { openURL(u) } }
                    ForEach(recipes, id: \.0) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.0).font(.headline)
                            Text(r.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("PowerPilot actions (for your own shortcuts)") {
                    ForEach(intentActions, id: \.0) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.0).font(.subheadline.bold())
                            Text(a.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Shortcuts")
        }
    }
}
