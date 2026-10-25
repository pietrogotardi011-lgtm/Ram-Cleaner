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
        "\(p.title): run the shortcut \"\(p.shortcutName)\".\n\(p.detail)\nBrightness target: \(Int(p.brightness * 100))%."
    }
}

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func statusText(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "Allowed"
        case .denied: return "Blocked in iOS Settings"
        case .notDetermined: return "Not asked yet"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }

    @discardableResult
    static func post(title: String, body: String, delay: TimeInterval = 0) async -> Bool {
        let c = UNUserNotificationCenter.current()
        var st = await c.notificationSettings().authorizationStatus
        if st == .notDetermined {
            _ = try? await c.requestAuthorization(options: [.alert, .sound])
            st = await c.notificationSettings().authorizationStatus
        }
        guard st == .authorized || st == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger: UNNotificationTrigger? = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
        do {
            try await c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
            return true
        } catch { return false }
    }

    private static func cooldownOK(_ kind: String) -> Bool {
        let last = UserDefaults.standard.double(forKey: "last_\(kind)")
        return Date().timeIntervalSince1970 - last > 1800
    }
    private static func mark(_ kind: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_\(kind)")
    }

    /// Returns the alert messages that currently apply. Posts notifications; `force` ignores the 30 min cooldown.
    static func evaluate(_ s: Snapshot, force: Bool = false) async -> [String] {
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
            if Prefs.notify && f.enabled && (force || cooldownOK(f.kind)) {
                if await post(title: f.title, body: f.body) { mark(f.kind) }
            }
        }
        return msgs
    }
}
