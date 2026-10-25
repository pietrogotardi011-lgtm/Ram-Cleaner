import Foundation

struct ShortcutInfo: Identifiable {
    let name: String
    let summary: String
    var id: String { name }
    var link: String { ShortcutLinks.links[name] ?? "" }
    var runURL: URL? {
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return URL(string: "shortcuts://x-callback-url/run-shortcut?name=\(n)&x-success=powerpilot://done")
    }
}

enum ShortcutLinks {
    /// Paste the iCloud share links here after signing the shortcuts.
    static let links: [String: String] = [
        "PowerPilot Max Battery": "",
        "PowerPilot Cool Down": "",
        "PowerPilot Performance": "",
        "PowerPilot Overnight": "",
        "PowerPilot Normal": "",
        "PowerPilot Unplug Alert": "",
        "PowerPilot Heat Check": "",
        "PowerPilot Log": ""
    ]

    static let all: [ShortcutInfo] = [
        ShortcutInfo(name: "PowerPilot Max Battery", summary: "Low Power Mode on, brightness 30%, Bluetooth off"),
        ShortcutInfo(name: "PowerPilot Cool Down", summary: "Low Power Mode on, brightness 20%, Bluetooth off"),
        ShortcutInfo(name: "PowerPilot Performance", summary: "Low Power Mode off, brightness 70%, Wi-Fi on"),
        ShortcutInfo(name: "PowerPilot Overnight", summary: "Low Power Mode on, brightness 0%, Bluetooth off"),
        ShortcutInfo(name: "PowerPilot Normal", summary: "Restores Low Power Mode off, brightness 60%, Bluetooth and Wi-Fi on"),
        ShortcutInfo(name: "PowerPilot Unplug Alert", summary: "Shows an \"unplug now\" notification"),
        ShortcutInfo(name: "PowerPilot Heat Check", summary: "Runs PowerPilot's Check and Alert (heat, charge, low battery)"),
        ShortcutInfo(name: "PowerPilot Log", summary: "Adds a point to PowerPilot's history")
    ]
}
