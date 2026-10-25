import AppIntents

enum IntensityOption: String, AppEnum {
    case useDefault, light, medium, heavy
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Intensity"
    static var caseDisplayRepresentations: [IntensityOption: DisplayRepresentation] = [
        .useDefault: "App setting", .light: "Light", .medium: "Medium", .heavy: "Heavy"
    ]
}

struct CleanMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Clean Memory"
    static var description = IntentDescription("Runs a RamTidy cleaning pass.")
    static var openAppWhenRun = false

    @Parameter(title: "Intensity", default: .useDefault)
    var intensity: IntensityOption

    @Parameter(title: "Show notification", default: false)
    var forceNotify: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let level = Intensity(rawValue: intensity.rawValue) ?? Prefs.intensity
        let r = await Cleaner.run(intensity: level, notify: Prefs.notify || forceNotify)
        return .result(value: r.summary)
    }
}

struct RamTidyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CleanMemoryIntent(),
                    phrases: ["Clean memory with \(.applicationName)", "Run \(.applicationName)"],
                    shortTitle: "Clean Memory", systemImageName: "memorychip")
    }
}
