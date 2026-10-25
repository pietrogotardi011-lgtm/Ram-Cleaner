import Foundation
import UserNotifications

struct Tip: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let severity: Int   // 0 ok, 1 warning, 2 alert
}

enum Advice {
    static func tips(for s: Snapshot) -> [Tip] {
        var t: [Tip] = []
        if s.thermal >= 3 {
            t.append(Tip(icon: "flame.fill", text: "Critical heat. Stop charging, remove the case, close apps and move to a cooler place.", severity: 2))
        } else if s.thermal == 2 {
            t.append(Tip(icon: "thermometer.high", text: "The phone is hot and iOS is throttling performance. Close heavy apps, pause charging, remove the case.", severity: 2))
        } else if s.thermal == 1 {
            t.append(Tip(icon: "thermometer.medium", text: "The phone is warming up. Light throttling may start; avoid gaming while charging.", severity: 1))
        }
        if s.level >= 0 && !s.charging && s.level <= Prefs.lowLevel && !s.lowPower {
            t.append(Tip(icon: "battery.25", text: "Battery is low. Turn on Low Power Mode to stretch what is left.", severity: 2))
        }
        if s.charging && s.level >= Prefs.chargeLimit && !s.full {
            t.append(Tip(icon: "bolt.slash.fill", text: "You reached your \(Prefs.chargeLimit)% limit. Unplugging now reduces long-term battery wear.", severity: 1))
        }
        if s.charging && s.thermal >= 1 {
            t.append(Tip(icon: "powerplug.fill", text: "Charging while warm slows charging and ages the battery. Try a slower charger or remove the case.", severity: 1))
        }
        if s.lowPower && !s.charging && s.level > 50 {
            t.append(Tip(icon: "gauge.with.dots.needle.67percent", text: "Low Power Mode is on with plenty of charge. Turn it off for full performance.", severity: 0))
        }
        if t.isEmpty {
            t.append(Tip(icon: "checkmark.seal.fill", text: "Everything looks healthy. No action needed.", severity: 0))
        }
        return t
    }

    static func steps(_ p: PowerProfileOption) -> String {
        let lines: [String]
        switch p {
        case .maxBattery:
            lines = ["Max Battery profile. Run these Shortcuts actions:",
                     "1. Set Low Power Mode → On",
                     "2. Set Brightness → 30%",
                     "3. Set Appearance → Dark",
                     "4. Set Bluetooth → Off (if unused)",
                     "5. Set Cellular Data → Wi-Fi only when at home"]
        case .cooldown:
            lines = ["Cool Down profile. Run these Shortcuts actions:",
                     "1. Set Brightness → 20%",
                     "2. Set Low Power Mode → On",
                     "3. Set Bluetooth → Off",
                     "4. Stop charging and remove the case",
                     "5. Close heavy apps and wait a few minutes"]
        case .performance:
            lines = ["Performance profile. Run these Shortcuts actions:",
                     "1. Set Low Power Mode → Off",
                     "2. Set Brightness → 70%",
                     "3. Set Wi-Fi → On",
                     "4. Keep the phone cool; heat is what throttles speed"]
        case .overnight:
            lines = ["Overnight profile. Run these Shortcuts actions:",
                     "1. Set Low Power Mode → On",
                     "2. Set Brightness → 0%",
                     "3. Set Bluetooth → Off",
                     "4. Turn on a Sleep Focus",
                     "5. Unplug around \(Prefs.chargeLimit)% if you charge manually"]
        }
        return lines.joined(separator: "\n")
    }
}

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) async {
        let c = UNUserNotificationCenter.current()
        let s = await c.notificationSettings()
        guard s.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func cooldownOK(_ kind: String) -> Bool {
        let last = UserDefaults.standard.double(forKey: "last_\(kind)")
        return Date().timeIntervalSince1970 - last > 1800
    }
    private static func mark(_ kind: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_\(kind)")
    }

    /// Returns the alert messages that currently apply; posts notifications (30 min cooldown per kind).
    static func evaluate(_ s: Snapshot) async -> [String] {
        var found: [(kind: String, enabled: Bool, title: String, body: String)] = []
        if s.thermal >= Prefs.hotThreshold {
            found.append(("hot", Prefs.notifyHot, "Phone is hot",
                          "Thermal state: \(s.thermalName). Close heavy apps and pause charging."))
        }
        if s.charging && s.level >= Prefs.chargeLimit && !s.full {
            found.append(("charge", Prefs.notifyCharge, "Unplug now",
                          "Battery reached \(s.level)%. Unplug to reduce battery wear."))
        }
        if !s.charging && s.level >= 0 && s.level <= Prefs.lowLevel {
            found.append(("low", Prefs.notifyLow, "Battery low",
                          "Battery at \(s.level)%. Turn on Low Power Mode."))
        }
        var msgs: [String] = []
        for f in found {
            msgs.append(f.body)
            if Prefs.notify && f.enabled && cooldownOK(f.kind) {
                await post(title: f.title, body: f.body)
                mark(f.kind)
            }
        }
        return msgs
    }
}
