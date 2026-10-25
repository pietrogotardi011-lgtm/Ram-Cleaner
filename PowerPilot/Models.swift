import Foundation
import UIKit

struct Snapshot: Codable, Identifiable, Hashable {
    let date: Date
    let level: Int        // -1 = unknown
    let charging: Bool
    let full: Bool
    let lowPower: Bool
    let thermal: Int      // 0 nominal, 1 fair, 2 serious, 3 critical
    var id: Date { date }

    static let placeholder = Snapshot(date: Date(), level: -1, charging: false, full: false, lowPower: false, thermal: 0)

    var thermalName: String { ["Nominal", "Fair", "Serious", "Critical"][min(max(thermal, 0), 3)] }
    var levelText: String { level < 0 ? "—" : "\(level)%" }
    var summary: String {
        let state = full ? "full" : (charging ? "charging" : "on battery")
        return "Battery \(levelText), \(state) · Low Power Mode \(lowPower ? "on" : "off") · Thermal: \(thermalName)"
    }
}

@MainActor
enum Monitor {
    static func snapshot() -> Snapshot {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        let raw = d.batteryLevel
        let level = raw < 0 ? -1 : Int((raw * 100).rounded())
        let st = d.batteryState
        let thermal: Int
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = 0
        case .fair: thermal = 1
        case .serious: thermal = 2
        case .critical: thermal = 3
        @unknown default: thermal = 0
        }
        return Snapshot(date: Date(), level: level,
                        charging: st == .charging || st == .full,
                        full: st == .full,
                        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        thermal: thermal)
    }
}

enum Store {
    private static let key = "history"
    static func load() -> [Snapshot] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Snapshot].self, from: d)) ?? []
    }
    private static func save(_ h: [Snapshot]) {
        if let d = try? JSONEncoder().encode(h) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func append(_ s: Snapshot) {
        var h = load()
        if let last = h.last, s.date.timeIntervalSince(last.date) < 60 { return }
        h.append(s)
        if h.count > 600 { h.removeFirst(h.count - 600) }
        save(h)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

enum Keys {
    static let notify = "notify"
    static let notifyHot = "notifyHot"
    static let notifyCharge = "notifyCharge"
    static let notifyLow = "notifyLow"
    static let chargeLimit = "chargeLimit"
    static let lowLevel = "lowLevel"
    static let hotThreshold = "hotThreshold"
    static let autoLog = "autoLog"
    static let intervalMinutes = "intervalMinutes"
    static let appearance = "appearance"
}

enum Prefs {
    private static func bool(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    private static func int(_ k: String, _ d: Int) -> Int { UserDefaults.standard.object(forKey: k) as? Int ?? d }
    static var notify: Bool { bool(Keys.notify, true) }
    static var notifyHot: Bool { bool(Keys.notifyHot, true) }
    static var notifyCharge: Bool { bool(Keys.notifyCharge, true) }
    static var notifyLow: Bool { bool(Keys.notifyLow, true) }
    static var chargeLimit: Int { int(Keys.chargeLimit, 80) }
    static var lowLevel: Int { int(Keys.lowLevel, 20) }
    static var hotThreshold: Int { int(Keys.hotThreshold, 2) }
    static var autoLog: Bool { bool(Keys.autoLog, true) }
    static var intervalMinutes: Int { int(Keys.intervalMinutes, 15) }
}
