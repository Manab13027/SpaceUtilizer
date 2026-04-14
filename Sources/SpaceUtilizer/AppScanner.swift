import Foundation
import AppKit

class AppScanner: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var isScanning = false
    @Published var scanProgress: Double = 0
    @Published var statusMessage = "Click Scan to begin"

    private let fm = FileManager.default

    // MARK: - Public

    func scan() {
        guard !isScanning else { return }
        DispatchQueue.main.async {
            self.isScanning = true
            self.apps = []
            self.scanProgress = 0
            self.statusMessage = "Finding applications..."
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let urls = self.findAllAppURLs()
            var results: [AppInfo] = []

            for (i, url) in urls.enumerated() {
                let name = url.deletingPathExtension().lastPathComponent
                let progress = Double(i + 1) / Double(max(urls.count, 1))
                DispatchQueue.main.async {
                    self.scanProgress = progress
                    self.statusMessage = "Scanning \(name)..."
                }
                results.append(self.buildAppInfo(for: url))
            }

            let sorted = results.sorted { $0.totalSize > $1.totalSize }
            DispatchQueue.main.async {
                self.apps = sorted
                self.isScanning = false
                self.scanProgress = 1.0
                self.statusMessage = "Found \(sorted.count) applications"
            }
        }
    }

    func moveToTrash(_ url: URL, completion: @escaping (Error?) -> Void) {
        trashViaFinder(url, completion: completion)
    }

    func deleteAppCompletely(_ app: AppInfo, completion: @escaping (Error?) -> Void) {
        // Trash the .app first, then associated files one by one
        moveToTrash(app.path) { error in
            if let error { completion(error); return }
            let files = app.associatedFiles
            self.trashSequentially(files: files, index: 0, completion: completion)
        }
    }

    private func trashSequentially(files: [AssociatedFile], index: Int, completion: @escaping (Error?) -> Void) {
        guard index < files.count else { completion(nil); return }
        moveToTrash(files[index].path) { _ in
            // Continue even if an individual associated file fails
            self.trashSequentially(files: files, index: index + 1, completion: completion)
        }
    }

    func removeAssociatedFile(_ file: AssociatedFile, from app: AppInfo) {
        app.associatedFiles.removeAll { $0.id == file.id }
    }

    func removeApp(_ app: AppInfo) {
        DispatchQueue.main.async { self.apps.removeAll { $0.id == app.id } }
    }

    // MARK: - Discovery

    private func findAllAppURLs() -> [URL] {
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications"),
        ]
        var found: [URL] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "app" {
                let key = item.resolvingSymlinksInPath().path
                guard seen.insert(key).inserted else { continue }
                found.append(item)
            }
        }
        return found
    }

    // MARK: - Build AppInfo

    private func buildAppInfo(for url: URL) -> AppInfo {
        let name = url.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier
        let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        let appSize = dirSize(url)
        let lastUsed = try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let associated = findAssociatedFiles(name: name, bundleID: bundleID)
        let dataFolders = findDataFolders(name: name, bundleID: bundleID)
        return AppInfo(name: name, path: url, bundleID: bundleID, appSize: appSize,
                       lastUsed: lastUsed, version: version, icon: icon,
                       associatedFiles: associated, dataFolders: dataFolders)
    }

    // MARK: - Known Data Paths

    // Apps that store large data outside the standard Library locations.
    // Key = app name as it appears in /Applications (case-insensitive match).
    private static let knownDataPaths: [String: [(label: String, path: String, description: String)]] = [
        "Ollama": [
            ("Models",  "~/.ollama/models",  "AI model weights downloaded by Ollama"),
            ("Blobs",   "~/.ollama/blobs",   "Model blob/chunk storage"),
        ],
        "Docker": [
            ("Images & Volumes", "~/Library/Containers/com.docker.docker/Data/vms",   "Docker VM disk images"),
            ("Volumes",          "~/Library/Containers/com.docker.docker/Data/volumes", "Named Docker volumes"),
            ("Config",           "~/.docker",                                           "Docker CLI config & credentials"),
        ],
        "Xcode": [
            ("Derived Data",       "~/Library/Developer/Xcode/DerivedData",               "Build artifacts — safe to delete"),
            ("iOS Device Support", "~/Library/Developer/Xcode/iOS DeviceSupport",          "Per-device debug symbols"),
            ("Simulator Runtimes", "~/Library/Developer/CoreSimulator/Volumes",            "Simulator OS images"),
            ("Simulators",         "~/Library/Developer/CoreSimulator/Devices",            "Simulator device data"),
            ("Archives",           "~/Library/Developer/Xcode/Archives",                  "App archives & dSYMs"),
            ("Documentation",      "~/Library/Developer/Xcode/DocumentationCache",        "Offline doc cache"),
        ],
        "Simulator": [
            ("Simulator Devices",  "~/Library/Developer/CoreSimulator/Devices",  "Simulator device data"),
            ("Simulator Runtimes", "~/Library/Developer/CoreSimulator/Volumes",  "Simulator OS images"),
        ],
        "Android Studio": [
            ("Android SDK",  "~/Library/Android/sdk",  "Android SDK platforms, build tools & NDK"),
            ("Emulators",    "~/.android/avd",          "Android Virtual Device disk images"),
            ("Gradle Cache", "~/.gradle/caches",        "Build cache — safe to delete"),
        ],
        "Steam": [
            ("Games", "~/Library/Application Support/Steam/steamapps", "Downloaded Steam games"),
        ],
        "Spotify": [
            ("Cache",   "~/Library/Caches/com.spotify.client",                           "Streaming cache — safe to delete"),
            ("Offline", "~/Library/Application Support/Spotify/PersistentCache",         "Offline saved content"),
        ],
        "Slack": [
            ("Cache", "~/Library/Application Support/Slack/Cache", "Message & media cache — safe to delete"),
        ],
        "zoom.us": [
            ("Recordings", "~/Documents/Zoom", "Local meeting recordings"),
        ],
        "Cursor": [
            ("Extensions", "~/.cursor/extensions", "Installed Cursor editor extensions"),
        ],
        "Code": [
            ("Extensions", "~/.vscode/extensions", "Installed VS Code extensions"),
        ],
        "Parallels Desktop": [
            ("Virtual Machines", "~/Parallels", "Parallels VM disk images (.pvm)"),
        ],
        "VMware Fusion": [
            ("Virtual Machines", "~/Virtual Machines.localized", "VMware VM disk images (.vmwarevm)"),
        ],
        "Logic Pro": [
            ("Sound Library", "~/Library/Application Support/Logic",         "Audio samples & patches"),
            ("GarageBand",    "~/Library/Application Support/GarageBand",    "Shared GarageBand assets"),
        ],
        "GarageBand": [
            ("Sound Library", "~/Library/Application Support/GarageBand", "Audio samples & patches"),
        ],
        "Final Cut Pro": [
            ("Motion Templates", "~/Movies/Motion Templates.localized", "Custom Motion templates"),
        ],
        "Dropbox": [
            ("Synced Files", "~/Dropbox", "All Dropbox synced content"),
        ],
        "Google Drive": [
            ("Synced Files", "~/Google Drive", "All Google Drive synced content"),
        ],
        "OneDrive": [
            ("Synced Files", "~/OneDrive", "All OneDrive synced content"),
        ],
        "Homebrew": [
            ("Cellar (Intel)",          "/usr/local/Cellar",          "Homebrew installed packages"),
            ("Cellar (Apple Silicon)",  "/opt/homebrew/Cellar",       "Homebrew installed packages"),
            ("Cache",                   "~/Library/Caches/Homebrew",  "Homebrew download cache — safe to delete"),
        ],
        "LM Studio": [
            ("Models", "~/.lmstudio/models", "AI models downloaded by LM Studio"),
        ],
        "TablePlus": [
            ("Connections", "~/Library/Application Support/com.tinyapp.TablePlus", "Saved DB connections"),
        ],
        "Figma": [
            ("Cache", "~/Library/Application Support/Figma/figma_app/Cache", "Figma app cache"),
        ],
    ]

    private func findDataFolders(name: String, bundleID: String?) -> [DataFolder] {
        let nameLow = name.lowercased()
        var entries: [(label: String, path: String, description: String)] = []
        for (key, vals) in Self.knownDataPaths {
            if nameLow == key.lowercased() || nameLow.hasPrefix(key.lowercased()) {
                entries = vals
                break
            }
        }
        guard !entries.isEmpty else { return [] }

        var results: [DataFolder] = []
        let home = NSHomeDirectory()
        for entry in entries {
            let expandedPath = entry.path.hasPrefix("~")
                ? home + entry.path.dropFirst()
                : entry.path
            let url = URL(fileURLWithPath: expandedPath)
            guard fm.fileExists(atPath: url.path) else { continue }
            // Size is -1 (not yet computed) — computed lazily when user selects the app
            results.append(DataFolder(label: entry.label, path: url,
                                      description: entry.description, size: -1))
        }
        return results
    }

    // Called when user selects an app — computes sizes of directories in background
    func computeSizesIfNeeded(for app: AppInfo) {
        DispatchQueue.global(qos: .utility).async {
            // Associated file directories
            for (i, file) in app.associatedFiles.enumerated() {
                guard file.size == -1 else { continue }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: file.path.path, isDirectory: &isDir)
                let size = isDir.boolValue ? self.dirSize(file.path) : self.fileSize(file.path)
                DispatchQueue.main.async { app.associatedFiles[i].size = size }
            }
            // Data folders
            for (i, folder) in app.dataFolders.enumerated() {
                guard folder.size == -1 else { continue }
                let size = self.dirSize(folder.path)
                DispatchQueue.main.async { app.dataFolders[i].size = size }
            }
        }
    }

    // MARK: - Associated Files

    private func findAssociatedFiles(name: String, bundleID: String?) -> [AssociatedFile] {
        var files: [AssociatedFile] = []
        let lib = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let ids = makeIdentifiers(name: name, bundleID: bundleID)

        // ~/Library/Preferences/<bundleID>.plist
        if let bid = bundleID {
            let pref = lib.appendingPathComponent("Preferences/\(bid).plist")
            if fm.fileExists(atPath: pref.path) {
                files.append(AssociatedFile(path: pref, size: fileSize(pref), category: .preferences))
            }
            // Additional plist variants like <bundleID>.LSSharedFileList.plist
            if let prefsItems = try? fm.contentsOfDirectory(at: lib.appendingPathComponent("Preferences"),
                                                             includingPropertiesForKeys: nil) {
                for item in prefsItems {
                    let fname = item.deletingPathExtension().lastPathComponent
                    if fname.hasPrefix(bid + ".") {
                        files.append(AssociatedFile(path: item, size: fileSize(item), category: .preferences))
                    }
                }
            }
        }

        // Subdirectory searches
        let subdirMap: [(String, FileCategory)] = [
            ("Application Support", .support),
            ("Caches", .cache),
            ("Logs", .logs),
        ]
        for (subdir, cat) in subdirMap {
            let base = lib.appendingPathComponent(subdir)
            for id in ids {
                let candidate = base.appendingPathComponent(id)
                if fm.fileExists(atPath: candidate.path) {
                    // Use -1 for directories — size computed lazily on selection
                    files.append(AssociatedFile(path: candidate, size: -1, category: cat))
                    break
                }
            }
        }

        // ~/Library/Containers/<bundleID>
        if let bid = bundleID {
            let container = lib.appendingPathComponent("Containers/\(bid)")
            if fm.fileExists(atPath: container.path) {
                files.append(AssociatedFile(path: container, size: -1, category: .containers))
            }
        }

        // Launch Agents
        let agentDirs = [
            lib.appendingPathComponent("LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
        ]
        for dir in agentDirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                let fname = item.deletingPathExtension().lastPathComponent.lowercased()
                let appLow = name.lowercased()
                let bidLow = bundleID?.lowercased() ?? ""
                if fname.contains(appLow) || (!bidLow.isEmpty && fname.contains(bidLow)) {
                    files.append(AssociatedFile(path: item, size: fileSize(item), category: .launchAgents))
                }
            }
        }

        return files
    }

    private func makeIdentifiers(name: String, bundleID: String?) -> [String] {
        var ids = [name]
        guard let bid = bundleID else { return ids }
        ids.append(bid)
        let parts = bid.split(separator: ".").map(String.init)
        if parts.count >= 2 {
            ids.append(parts.dropFirst().joined(separator: "."))
            if let last = parts.last { ids.append(last) }
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Size

    func dirSize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true, let sz = vals.fileSize else { continue }
            total += Int64(sz)
        }
        return total
    }

    func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
