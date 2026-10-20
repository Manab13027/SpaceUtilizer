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
        // Try FileManager first for everything — fast, and works for most apps in
        // /Applications too (drag-installed apps are owned by you).
        // Fall back to Finder (which can ask for your admin password) only for
        // system locations owned by root, e.g. App Store apps.
        let isSystemLocation = url.path.hasPrefix("/Applications") ||
                               url.path.hasPrefix("/Library") ||
                               url.path.hasPrefix("/usr/local") ||
                               url.path.hasPrefix("/opt")
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            DispatchQueue.main.async { completion(nil) }
            return
        } catch {
            if !isSystemLocation {
                DispatchQueue.main.async { completion(error) }
                return
            }
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

// MARK: - Paths & sizes

func tildePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// Real on-disk size of a file or folder (folders include hidden files).
func diskUsage(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
    if v.isSymbolicLink == true { return 0 }
    if v.isDirectory != true {
        return Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
    }
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
    var total: Int64 = 0
    for case let f as URL in e {
        guard let fv = try? f.resourceValues(forKeys: Set(keys)), fv.isRegularFile == true else { continue }
        total += Int64(fv.totalFileAllocatedSize ?? fv.fileSize ?? 0)
    }
    return total
}

// MARK: - Running command-line tools

/// Runs a tool and returns its stdout, or nil if it couldn't start.
/// Stops the tool after `timeout` seconds and returns whatever it printed so far.
func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> String? {
    guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }

    var data = Data()
    let reader = DispatchGroup()
    reader.enter()
    DispatchQueue.global(qos: .utility).async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        reader.leave()
    }
    if reader.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = reader.wait(timeout: .now() + 2)
    }
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
