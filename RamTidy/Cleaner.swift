import Foundation
import UserNotifications
import Darwin

struct CleanResult {
    let before: UInt64
    let after: UInt64
    var summary: String {
        let f = ByteCountFormatter()
        return "Footprint \(f.string(fromByteCount: Int64(before))) → \(f.string(fromByteCount: Int64(after)))"
    }
}

enum Cleaner {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func available() -> UInt64 { UInt64(os_proc_available_memory()) }

    @discardableResult
    static func run(intensity: Intensity, notify: Bool) async -> CleanResult {
        let before = footprint()

        URLCache.shared.removeAllCachedResponses()

        if intensity != .light {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            for url in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: url)
            }
        }

        if intensity == .heavy {
            await pressure()
        }

        let result = CleanResult(before: before, after: footprint())
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastRun)
        if notify { await post(result.summary) }
        return result
    }

    /// Allocates and touches memory in chunks so iOS evicts cached pages, then frees it.
    /// Capped well below the app's available limit so it can't get itself killed.
    private static func pressure() async {
        let chunk = 16 * 1024 * 1024
        let budget = min(UInt64(ProcessInfo.processInfo.physicalMemory) * 3 / 10,
                         available() * 7 / 10)
        var blocks: [UnsafeMutableRawPointer] = []
        var used: UInt64 = 0
        while used + UInt64(chunk) < budget {
            let p = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            memset(p, 1, chunk)
            blocks.append(p)
            used += UInt64(chunk)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        blocks.forEach { $0.deallocate() }
    }

    static func post(_ body: String) async {
        let c = UNUserNotificationCenter.current()
        let s = await c.notificationSettings()
        guard s.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Memory cleaned"
        content.body = body
        try? await c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
