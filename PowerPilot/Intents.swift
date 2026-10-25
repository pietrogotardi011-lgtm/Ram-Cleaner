import AppIntents

enum ThermalLevel: String, AppEnum {
    case nominal, fair, serious, critical
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Thermal State"
    static var caseDisplayRepresentations: [ThermalLevel: DisplayRepresentation] = [
        .nominal: "Nominal", .fair: "Fair", .serious: "Serious", .critical: "Critical"
    ]
    init(index: Int) {
        switch index {
        case 1: self = .fair
        case 2: self = .serious
        case 3: self = .critical
        default: self = .nominal
        }
    }
}

enum PowerProfileOption: String, AppEnum, CaseIterable {
    case maxBattery, cooldown, performance, overnight, normal
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Power Profile"
    static var caseDisplayRepresentations: [PowerProfileOption: DisplayRepresentation] = [
        .maxBattery: "Max Battery", .cooldown: "Cool Down", .performance: "Performance",
        .overnight: "Overnight", .normal: "Normal"
    ]
    var title: String {
        switch self {
        case .maxBattery: return "Max Battery"
        case .cooldown: return "Cool Down"
        case .performance: return "Performance"
        case .overnight: return "Overnight"
        case .normal: return "Normal"
        }
    }
    var shortcutName: String { "PowerPilot \(title)" }
    var brightness: Double {
        switch self {
        case .maxBattery: return 0.30
        case .cooldown: return 0.20
        case .performance: return 0.70
        case .overnight: return 0.0
        case .normal: return 0.60
        }
    }
    var detail: String {
        switch self {
        case .maxBattery: return "Low Power Mode on, brightness 30%, Bluetooth off. For when the battery is low."
        case .cooldown: return "Low Power Mode on, brightness 20%, Bluetooth off. For when the phone is hot."
        case .performance: return "Low Power Mode off, brightness 70%, Wi-Fi on. For full speed."
        case .overnight: return "Low Power Mode on, screen dark, Bluetooth off. For sleeping."
        case .normal: return "Restores Low Power Mode off, brightness 60%, Bluetooth and Wi-Fi on."
        }
    }
}

struct GetBatteryStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Battery Status"
    static var description = IntentDescription("Returns battery level, charging state, Low Power Mode and thermal state as text.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let s = await Monitor.snapshot()
        return .result(value: s.summary)
    }
}

struct GetBatteryLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Battery Level"
    static var description = IntentDescription("Returns the battery percentage as a number.")
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let s = await Monitor.snapshot()
        return .result(value: s.level)
    }
}

struct GetThermalStateIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Thermal State"
    static var description = IntentDescription("Returns the phone's thermal state: Nominal, Fair, Serious or Critical.")
    func perform() async throws -> some IntentResult & ReturnsValue<ThermalLevel> {
        let s = await Monitor.snapshot()
        return .result(value: ThermalLevel(index: s.thermal))
    }
}

struct IsPhoneHotIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Phone Hot?"
    static var description = IntentDescription("Yes when the thermal state is Serious or Critical (or Fair too, if enabled).")
    @Parameter(title: "Include Fair", default: false) var includeFair: Bool
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let s = await Monitor.snapshot()
        return .result(value: s.thermal >= (includeFair ? 1 : 2))
    }
}

struct IsChargingIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Charging?"
    static var description = IntentDescription("Yes when the phone is plugged in and charging or full.")
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let s = await Monitor.snapshot()
        return .result(value: s.charging)
    }
}

struct IsLowPowerModeOnIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Low Power Mode On?"
    static var description = IntentDescription("Yes when Low Power Mode is enabled.")
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let s = await Monitor.snapshot()
        return .result(value: s.lowPower)
    }
}

struct IsBatteryBelowIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Battery Below?"
    static var description = IntentDescription("Yes when the battery percentage is below the value you give.")
    @Parameter(title: "Percent", default: 20) var percent: Int
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let s = await Monitor.snapshot()
        return .result(value: s.level >= 0 && s.level < percent)
    }
}

struct ShouldUnplugIntent: AppIntent {
    static var title: LocalizedStringResource = "Should I Unplug?"
    static var description = IntentDescription("Yes when charging has reached the charge limit set in PowerPilot.")
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let s = await Monitor.snapshot()
        return .result(value: s.charging && s.level >= Prefs.chargeLimit)
    }
}

struct GetPowerTipsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Power Tips"
    static var description = IntentDescription("Returns tips based on the current battery and thermal state.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let s = await Monitor.snapshot()
        return .result(value: Advice.tips(for: s).map { $0.text }.joined(separator: "\n"))
    }
}

struct GetBatteryTrendIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Battery Trend"
    static var description = IntentDescription("Describes how fast the battery changed over the last 3 hours of logged data.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        let h = Store.load().filter { $0.date >= cutoff && $0.level >= 0 }
        guard let first = h.first, let last = h.last, h.count >= 2 else {
            return .result(value: "Not enough history yet. Enable auto-logging in PowerPilot.")
        }
        let hours = max(last.date.timeIntervalSince(first.date) / 3600, 0.01)
        let diff = last.level - first.level
        let rate = Double(diff) / hours
        let verb = diff >= 0 ? "rose" : "fell"
        return .result(value: "Battery \(verb) \(abs(diff))% in \(String(format: "%.1f", hours)) h (\(String(format: "%.1f", abs(rate)))%/h).")
    }
}

struct CheckAndAlertIntent: AppIntent {
    static var title: LocalizedStringResource = "Check and Alert"
    static var description = IntentDescription("Checks heat, charge limit and low battery, sends notifications per your settings, and returns what it found.")
    @Parameter(title: "Ignore cooldown", default: false) var ignoreCooldown: Bool
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let s = await Monitor.snapshot()
        Store.append(s)
        let msgs = await Notifier.evaluate(s, force: ignoreCooldown)
        return .result(value: msgs.isEmpty ? "All clear. \(s.summary)" : msgs.joined(separator: "\n"))
    }
}

struct LogSnapshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Battery Snapshot"
    static var description = IntentDescription("Saves the current battery and thermal state to PowerPilot's history.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let s = await Monitor.snapshot()
        Store.append(s)
        return .result(value: "Logged: \(s.summary)")
    }
}

struct ApplyPowerProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Power Profile"
    static var description = IntentDescription("Returns the Shortcuts steps for a power profile. Add Apple's system actions after it to apply them.")
    @Parameter(title: "Profile", default: .maxBattery) var profile: PowerProfileOption
    @Parameter(title: "Show notification", default: false) var showNotification: Bool
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = Advice.steps(profile)
        if showNotification {
            await Notifier.post(title: "PowerPilot: \(profile.title)", body: "Profile suggested. Run the matching actions in your shortcut.")
        }
        return .result(value: text)
    }
}

struct PowerPilotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetBatteryStatusIntent(),
                    phrases: ["Battery status in \(.applicationName)", "Check my phone with \(.applicationName)"],
                    shortTitle: "Battery Status", systemImageName: "battery.100")
        AppShortcut(intent: IsPhoneHotIntent(),
                    phrases: ["Is my phone hot in \(.applicationName)"],
                    shortTitle: "Is Phone Hot?", systemImageName: "thermometer.high")
        AppShortcut(intent: GetThermalStateIntent(),
                    phrases: ["Thermal state in \(.applicationName)"],
                    shortTitle: "Thermal State", systemImageName: "thermometer.medium")
        AppShortcut(intent: ShouldUnplugIntent(),
                    phrases: ["Should I unplug with \(.applicationName)"],
                    shortTitle: "Should I Unplug?", systemImageName: "bolt.slash.fill")
        AppShortcut(intent: CheckAndAlertIntent(),
                    phrases: ["Check and alert with \(.applicationName)"],
                    shortTitle: "Check and Alert", systemImageName: "bell.badge")
        AppShortcut(intent: ApplyPowerProfileIntent(),
                    phrases: ["Apply a power profile in \(.applicationName)"],
                    shortTitle: "Apply Power Profile", systemImageName: "bolt.circle")
        AppShortcut(intent: GetPowerTipsIntent(),
                    phrases: ["Power tips from \(.applicationName)"],
                    shortTitle: "Power Tips", systemImageName: "lightbulb")
        AppShortcut(intent: GetBatteryTrendIntent(),
                    phrases: ["Battery trend in \(.applicationName)"],
                    shortTitle: "Battery Trend", systemImageName: "chart.line.downtrend.xyaxis")
    }
}
