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
        guard !Self.isProtectedPath(url) else {
            completion(NSError(domain: "SpaceUtilizer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(url.path) is a protected system or home folder and was not touched."
            ]))
            return
        }
        trashViaFinder(url, completion: completion)
    }

    /// Moves every URL to the Trash one after another. Keeps going if one fails.
    /// `progress` is called on the main thread with (done, total).
    /// `completion` gets the list of items that could not be trashed.
    func trashAll(_ urls: [URL],
                  progress: @escaping (Int, Int) -> Void,
                  completion: @escaping ([(url: URL, error: Error)]) -> Void) {
        var failures: [(url: URL, error: Error)] = []
        func step(_ index: Int) {
            progress(index, urls.count)
            guard index < urls.count else { completion(failures); return }
            let url = urls[index]
            // Already gone (e.g. it lived inside a folder we just trashed) — nothing to do.
            guard fm.fileExists(atPath: url.path) else { step(index + 1); return }
            moveToTrash(url) { error in
                if let error { failures.append((url, error)) }
                step(index + 1)
            }
        }
        step(0)
    }

    func removeAssociatedFile(_ file: AssociatedFile, from app: AppInfo) {
        app.associatedFiles.removeAll { $0.id == file.id }
    }

    func removeApp(_ app: AppInfo) {
        DispatchQueue.main.async { self.apps.removeAll { $0.id == app.id } }
    }

    // MARK: - Safety

    /// Folders that must never be trashed as a whole, no matter what an app entry says.
    /// Extra folders that must never be trashed whole (e.g. your project root folders).
    static var extraProtectedPaths: Set<String> = []

    static func isProtectedPath(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        if extraProtectedPaths.contains(p) || extraProtectedPaths.contains(url.standardizedFileURL.path) { return true }
        let home = NSHomeDirectory()
        let protected: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/usr", "/usr/local", "/opt", "/opt/homebrew",
            home,
            home + "/Library", home + "/Library/Application Support", home + "/Library/Caches",
            home + "/Library/Containers", home + "/Library/Group Containers", home + "/Library/Preferences",
            home + "/Library/Logs", home + "/Library/Developer",
            home + "/Applications", home + "/Documents", home + "/Desktop", home + "/Downloads",
            home + "/Movies", home + "/Music", home + "/Pictures", home + "/Public",
            home + "/.cache", home + "/.config", home + "/.local", home + "/.local/share",
        ]
        return protected.contains(p) || p.count <= 1
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
        let assocPaths = Set(associated.map { $0.path.standardizedFileURL.path })
        let dataFolders = findDataFolders(name: name, bundleID: bundleID)
            .filter { !assocPaths.contains($0.path.standardizedFileURL.path) }
        return AppInfo(name: name, path: url, bundleID: bundleID, appSize: appSize,
                       lastUsed: lastUsed, version: version, icon: icon,
                       associatedFiles: associated, dataFolders: dataFolders)
    }

    // MARK: - Known Data Paths

    private struct KnownPath {
        let label: String
        let path: String
        let description: String
        let kind: DataKind
        init(_ label: String, _ path: String, _ description: String, _ kind: DataKind = .appData) {
            self.label = label; self.path = path; self.description = description; self.kind = kind
        }
    }

    // Apps that store large data outside the standard Library locations.
    // Key = app name as it appears in /Applications (case-insensitive, prefix match).
    // Kind decides the default in "Uninstall Completely":
    //   .appData       → ticked (models, caches, VMs the app owns)
    //   .userContent   → unticked (your recordings, archives, synced files)
    //   .sharedLibrary → unticked (SDKs / package caches other tools use)
    private static let knownDataPaths: [String: [KnownPath]] = [
        "Ollama": [
            KnownPath("Models & Data", "~/.ollama", "AI model weights, keys and history downloaded by Ollama"),
        ],
        "LM Studio": [
            KnownPath("Models & Data", "~/.lmstudio", "AI models downloaded by LM Studio"),
            KnownPath("Legacy Models", "~/.cache/lm-studio", "Models from older LM Studio versions"),
        ],
        "Jan": [
            KnownPath("Models & Data", "~/jan", "Models and chats downloaded by Jan"),
            KnownPath("App Data", "~/Library/Application Support/Jan", "Jan models and settings"),
        ],
        "GPT4All": [
            KnownPath("Models & Data", "~/Library/Application Support/nomic.ai", "GPT4All models and chats"),
        ],
        "Msty": [
            KnownPath("Models & Data", "~/Library/Application Support/Msty", "Msty models and chats"),
        ],
        "AnythingLLM": [
            KnownPath("Models & Data", "~/Library/Application Support/anythingllm-desktop", "AnythingLLM models, vectors and documents"),
        ],
        "DiffusionBee": [
            KnownPath("Models & Data", "~/.diffusionbee", "Stable Diffusion models downloaded by DiffusionBee"),
        ],
        "Pinokio": [
            KnownPath("Apps & Models", "~/pinokio", "AI apps, environments and models installed through Pinokio"),
        ],
        "Docker": [
            KnownPath("VM Disk Images", "~/Library/Containers/com.docker.docker/Data/vms", "Docker VM disk images (images, containers, volumes)"),
            KnownPath("Volumes", "~/Library/Containers/com.docker.docker/Data/volumes", "Named Docker volumes"),
            KnownPath("Docker Desktop Data", "~/Library/Group Containers/group.com.docker", "Docker Desktop shared data"),
            KnownPath("Config", "~/.docker", "Docker CLI config & credentials"),
        ],
        "Xcode": [
            KnownPath("Derived Data", "~/Library/Developer/Xcode/DerivedData", "Build artifacts — safe to delete"),
            KnownPath("iOS Device Support", "~/Library/Developer/Xcode/iOS DeviceSupport", "Per-device debug symbols"),
            KnownPath("Simulator Runtimes", "~/Library/Developer/CoreSimulator/Volumes", "Simulator OS images"),
            KnownPath("Simulators", "~/Library/Developer/CoreSimulator/Devices", "Simulator device data"),
            KnownPath("Simulator Caches", "~/Library/Developer/CoreSimulator/Caches", "Simulator caches"),
            KnownPath("Documentation", "~/Library/Developer/Xcode/DocumentationCache", "Offline doc cache"),
            KnownPath("Archives", "~/Library/Developer/Xcode/Archives", "Your app archives & dSYMs", .userContent),
        ],
        "Simulator": [
            KnownPath("Simulator Devices", "~/Library/Developer/CoreSimulator/Devices", "Simulator device data"),
            KnownPath("Simulator Runtimes", "~/Library/Developer/CoreSimulator/Volumes", "Simulator OS images"),
        ],
        "Android Studio": [
            KnownPath("Emulators", "~/.android/avd", "Android Virtual Device disk images"),
            KnownPath("Android SDK", "~/Library/Android/sdk", "SDK platforms, build tools & NDK — also used by Flutter / React Native / CLI builds", .sharedLibrary),
            KnownPath("Gradle Cache", "~/.gradle/caches", "Gradle dependency cache shared by all Gradle builds", .sharedLibrary),
        ],
        "Steam": [
            KnownPath("Games", "~/Library/Application Support/Steam/steamapps", "Downloaded Steam games"),
        ],
        "Spotify": [
            KnownPath("Cache", "~/Library/Caches/com.spotify.client", "Streaming cache — safe to delete"),
            KnownPath("Offline", "~/Library/Application Support/Spotify/PersistentCache", "Offline saved content"),
        ],
        "Slack": [
            KnownPath("Cache", "~/Library/Application Support/Slack/Cache", "Message & media cache — safe to delete"),
        ],
        "zoom.us": [
            KnownPath("Recordings", "~/Documents/Zoom", "Local meeting recordings", .userContent),
        ],
        "Cursor": [
            KnownPath("Extensions", "~/.cursor", "Installed Cursor extensions and settings"),
        ],
        "Visual Studio Code": [
            KnownPath("Extensions", "~/.vscode", "Installed VS Code extensions"),
        ],
        "Code": [
            KnownPath("Extensions", "~/.vscode", "Installed VS Code extensions"),
        ],
        "Parallels Desktop": [
            KnownPath("Virtual Machines", "~/Parallels", "Parallels VM disk images (.pvm) — may contain your work", .userContent),
        ],
        "VMware Fusion": [
            KnownPath("Virtual Machines", "~/Virtual Machines.localized", "VMware VM disk images — may contain your work", .userContent),
        ],
        "UTM": [
            KnownPath("Virtual Machines", "~/Library/Containers/com.utmapp.UTM/Data/Documents", "UTM VM disk images — may contain your work", .userContent),
        ],
        "Logic Pro": [
            KnownPath("Sound Library", "~/Library/Application Support/Logic", "Logic audio samples & patches"),
            KnownPath("GarageBand Library", "~/Library/Application Support/GarageBand", "Assets shared with GarageBand", .sharedLibrary),
        ],
        "GarageBand": [
            KnownPath("Sound Library", "~/Library/Application Support/GarageBand", "Audio samples & patches"),
        ],
        "Final Cut Pro": [
            KnownPath("Motion Templates", "~/Movies/Motion Templates.localized", "Custom Motion templates", .userContent),
        ],
        "Dropbox": [
            KnownPath("Synced Files", "~/Dropbox", "All Dropbox synced content", .userContent),
        ],
        "Google Drive": [
            KnownPath("Synced Files", "~/Google Drive", "All Google Drive synced content", .userContent),
        ],
        "OneDrive": [
            KnownPath("Synced Files", "~/OneDrive", "All OneDrive synced content", .userContent),
        ],
        "Homebrew": [
            KnownPath("Cache", "~/Library/Caches/Homebrew", "Homebrew download cache — safe to delete"),
            KnownPath("Cellar (Intel)", "/usr/local/Cellar", "Installed Homebrew packages", .sharedLibrary),
            KnownPath("Cellar (Apple Silicon)", "/opt/homebrew/Cellar", "Installed Homebrew packages", .sharedLibrary),
        ],
        "TablePlus": [
            KnownPath("Connections", "~/Library/Application Support/com.tinyapp.TablePlus", "Saved DB connections"),
        ],
        "Figma": [
            KnownPath("Cache", "~/Library/Application Support/Figma/figma_app/Cache", "Figma app cache"),
        ],
    ]

    /// Hidden home folders that belong to languages / toolchains, never to a single app.
    /// Matching an app name against these would delete Python, Node, Rust… so they are skipped.
    private static let sharedDotFolders: Set<String> = [
        "python", "pyenv", "pip", "conda", "anaconda", "miniconda", "miniforge", "mamba", "poetry", "virtualenvs",
        "venv", "uv", "npm", "node", "nvm", "yarn", "pnpm", "bun", "deno", "cargo", "rustup", "go", "gem", "rbenv",
        "rvm", "m2", "gradle", "sdkman", "jenv", "android", "local", "config", "cache", "ssh", "gnupg", "git",
        "zsh", "bash", "vim", "oh-my-zsh", "kube", "aws", "azure", "gcloud", "terraform", "colima", "lima",
        // Shared with command-line tools of the same name — deleting the desktop app must not wipe the CLI's data
        "claude", "codex", "gemini", "copilot", "aider", "huggingface", "keras", "torch", "jupyter", "ipython",
    ]

    private func findDataFolders(name: String, bundleID: String?) -> [DataFolder] {
        let nameLow = name.lowercased()
        var entries: [KnownPath] = []
        // Exact name, or name followed by a word ("Android Studio Preview", "Logic Pro X").
        // Prefer the longest key so "Visual Studio Code" wins over "Code"; "Codex" does NOT match "Code".
        let keys = Self.knownDataPaths.keys.sorted { $0.count > $1.count }
        for key in keys where nameLow == key.lowercased() || nameLow.hasPrefix(key.lowercased() + " ") {
            entries = Self.knownDataPaths[key] ?? []
            break
        }

        // Generic: a hidden folder in home named after the app, e.g. ~/.ollama, ~/.someapp
        var candidates = [nameLow.replacingOccurrences(of: " ", with: "")]
        if let last = bundleID?.split(separator: ".").last.map({ String($0).lowercased() }), last.count >= 4 {
            candidates.append(last)
        }
        for c in Set(candidates) where c.count >= 3 && !Self.sharedDotFolders.contains(c) {
            let p = "~/." + c
            if !entries.contains(where: { $0.path == p }) {
                entries.append(KnownPath("Home Folder Data", p, "Hidden data folder in your home named after this app"))
            }
        }

        var results: [DataFolder] = []
        var seen = Set<String>()
        let home = NSHomeDirectory()
        for entry in entries {
            let expandedPath = entry.path.hasPrefix("~")
                ? home + entry.path.dropFirst()
                : entry.path
            let url = URL(fileURLWithPath: expandedPath)
            guard fm.fileExists(atPath: url.path),
                  !Self.isProtectedPath(url),
                  seen.insert(url.standardizedFileURL.path).inserted else { continue }
            // Size is -1 (not yet computed) — computed lazily when user selects the app
            results.append(DataFolder(label: entry.label, path: url,
                                      description: entry.description, kind: entry.kind, size: -1))
        }
        return results
    }

    // Called when user selects an app — computes sizes of directories in background
    func computeSizesIfNeeded(for app: AppInfo) {
        DispatchQueue.global(qos: .utility).async {
            // Associated file directories
            for file in app.associatedFiles where file.size == -1 {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: file.path.path, isDirectory: &isDir)
                let size = isDir.boolValue ? self.dirSize(file.path) : self.fileSize(file.path)
                DispatchQueue.main.async {
                    if let i = app.associatedFiles.firstIndex(where: { $0.id == file.id }) {
                        app.associatedFiles[i].size = size
                    }
                }
            }
            // Data folders
            for folder in app.dataFolders where folder.size == -1 {
                let size = self.dirSize(folder.path)
                DispatchQueue.main.async {
                    if let i = app.dataFolders.firstIndex(where: { $0.id == folder.id }) {
                        app.dataFolders[i].size = size
                    }
                }
            }
        }
    }

    // MARK: - Associated Files

    private func findAssociatedFiles(name: String, bundleID: String?) -> [AssociatedFile] {
        var files: [AssociatedFile] = []
        var seen = Set<String>()
        func add(_ url: URL, _ cat: FileCategory, lazySize: Bool) {
            guard fm.fileExists(atPath: url.path),
                  !Self.isProtectedPath(url),
                  seen.insert(url.standardizedFileURL.path).inserted else { return }
            files.append(AssociatedFile(path: url, size: lazySize ? -1 : fileSize(url), category: cat))
        }

        let lib = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let (strongIDs, weakIDs) = makeIdentifiers(name: name, bundleID: bundleID)

        // ~/Library/Preferences/<bundleID>.plist (+ variants like <bundleID>.LSSharedFileList.plist)
        if let bid = bundleID {
            add(lib.appendingPathComponent("Preferences/\(bid).plist"), .preferences, lazySize: false)
            if let prefsItems = try? fm.contentsOfDirectory(at: lib.appendingPathComponent("Preferences"),
                                                             includingPropertiesForKeys: nil) {
                for item in prefsItems where item.deletingPathExtension().lastPathComponent.hasPrefix(bid + ".") {
                    add(item, .preferences, lazySize: false)
                }
            }
        }

        // Application Support / Caches / Logs — every strong match, weak names only as fallback
        let subdirMap: [(String, FileCategory)] = [
            ("Application Support", .support),
            ("Caches", .cache),
            ("Logs", .logs),
        ]
        for (subdir, cat) in subdirMap {
            let base = lib.appendingPathComponent(subdir)
            var matched = false
            for id in strongIDs {
                let candidate = base.appendingPathComponent(id)
                if fm.fileExists(atPath: candidate.path) { add(candidate, cat, lazySize: true); matched = true }
            }
            if !matched {
                for id in weakIDs {
                    let candidate = base.appendingPathComponent(id)
                    if fm.fileExists(atPath: candidate.path) { add(candidate, cat, lazySize: true); break }
                }
            }
        }

        if let bid = bundleID {
            // Sandboxed container
            add(lib.appendingPathComponent("Containers/\(bid)"), .containers, lazySize: true)
            // Web data, cookies, saved window state, scripts
            add(lib.appendingPathComponent("HTTPStorages/\(bid)"), .cache, lazySize: true)
            add(lib.appendingPathComponent("HTTPStorages/\(bid).binarycookies"), .cache, lazySize: false)
            add(lib.appendingPathComponent("WebKit/\(bid)"), .cache, lazySize: true)
            add(lib.appendingPathComponent("Cookies/\(bid).binarycookies"), .other, lazySize: false)
            add(lib.appendingPathComponent("Saved Application State/\(bid).savedState"), .other, lazySize: true)
            add(lib.appendingPathComponent("Application Scripts/\(bid)"), .other, lazySize: true)

            // Group containers: "group.<bid>", "<TEAMID>.<bid>" …
            let bidLow = bid.lowercased()
            if let groups = try? fm.contentsOfDirectory(at: lib.appendingPathComponent("Group Containers"),
                                                         includingPropertiesForKeys: nil) {
                for g in groups {
                    let gname = g.lastPathComponent.lowercased()
                    if gname == bidLow || gname.hasSuffix("." + bidLow) {
                        add(g, .containers, lazySize: true)
                    }
                }
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
                    add(item, .launchAgents, lazySize: false)
                }
            }
        }

        return files
    }

    /// Strong identifiers (app name, full bundle ID) are always searched.
    /// Weak ones (bundle ID without vendor prefix, last component) are only used
    /// when no strong match exists, to avoid grabbing generic folders.
    private func makeIdentifiers(name: String, bundleID: String?) -> (strong: [String], weak: [String]) {
        var strong = [name]
        var weak: [String] = []
        if let bid = bundleID {
            strong.append(bid)
            let parts = bid.split(separator: ".").map(String.init)
            if parts.count >= 3 { weak.append(parts.dropFirst().joined(separator: ".")) }
            if let last = parts.last, last.count >= 4,
               !["app", "desktop", "mac", "macos", "client", "helper", "main"].contains(last.lowercased()) {
                weak.append(last)
            }
        }
        var seen = Set<String>()
        return (strong.filter { seen.insert($0).inserted }, weak.filter { seen.insert($0).inserted })
    }

    // MARK: - Size

    /// Real on-disk size, including hidden files (dot-folders like ~/.ollama keep data in hidden paths too).
    func dirSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true else { continue }
            total += Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
        }
        return total
    }

    func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
