import Foundation

enum Intensity: String, CaseIterable, Identifiable {
    case light, medium, heavy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .light: return "Clears the app's own URL cache"
        case .medium: return "Light + deletes temporary files"
        case .heavy: return "Medium + brief memory-pressure pass (experimental)"
        }
    }
}

enum Keys {
    static let intensity = "intensity"
    static let notify = "notify"
    static let background = "background"
    static let intervalMinutes = "intervalMinutes"
    static let lastRun = "lastRun"
}

enum Prefs {
    static var intensity: Intensity {
        Intensity(rawValue: UserDefaults.standard.string(forKey: Keys.intensity) ?? "") ?? .medium
    }
    static var notify: Bool {
        UserDefaults.standard.object(forKey: Keys.notify) as? Bool ?? true
    }
    static var background: Bool {
        UserDefaults.standard.object(forKey: Keys.background) as? Bool ?? true
    }
    static var intervalMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: Keys.intervalMinutes)
        return v == 0 ? 15 : v
    }
}
