import Foundation

func formatBytes(_ bytes: Int64) -> String {
    guard bytes >= 0 else { return "—" }
    let f = ByteCountFormatter()
    f.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

func relativeDate(_ date: Date?) -> String {
    guard let date = date else { return "Unknown" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
}

// MARK: - Shared trash

func trashViaFinder(_ url: URL, completion: @escaping (Error?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        // Use FileManager for user-owned paths — fast, no permissions needed.
        // Fall back to AppleScript only for system-protected locations like /Applications.
        let needsAppleScript = url.path.hasPrefix("/Applications") ||
                               url.path.hasPrefix("/Library") ||
                               url.path.hasPrefix("/System")

        if !needsAppleScript {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                // If FileManager fails too, surface the real error
                DispatchQueue.main.async { completion(error) }
            }
            return
        }

        // AppleScript path — only for /Applications etc.
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Finder"
            move POSIX file "\(escaped)" to trash
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        DispatchQueue.main.async {
            if let e = err {
                let msg = (e[NSAppleScript.errorMessage] as? String) ?? "Could not move to Trash"
                completion(NSError(domain: "SpaceUtilizer", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: msg]))
            } else {
                completion(nil)
            }
        }
    }
}

struct DiskInfo {
    let total: Int64
    let free: Int64
    var used: Int64 { total - free }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func load() -> DiskInfo? {
        let url = URL(fileURLWithPath: "/")
        guard let vals = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
        let total = vals.volumeTotalCapacity,
        let free = vals.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskInfo(total: Int64(total), free: free)
    }
}
