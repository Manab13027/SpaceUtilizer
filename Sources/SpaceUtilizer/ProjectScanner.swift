import Foundation
import AppKit
import Combine

// MARK: - Git status

struct GitStatus {
    var isRepo = false
    var branch = ""
    var uncommitted = 0
    var ahead = 0
    var hasRemote = false

    var warnings: [String] {
        guard isRepo else {
            return ["Not a git repository — once the Trash is emptied this code is gone for good."]
        }
        var w: [String] = []
        if uncommitted > 0 { w.append("\(uncommitted) uncommitted change\(uncommitted == 1 ? "" : "s") — not saved anywhere else.") }
        if !hasRemote { w.append("No git remote — this code isn't backed up on GitHub or anywhere else.") }
        else if ahead > 0 { w.append("\(ahead) commit\(ahead == 1 ? "" : "s") on \(branch) not pushed to the remote yet.") }
        return w
    }
}

// MARK: - ProjectInfo

final class ProjectInfo: ObservableObject, Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let kinds: [String]
    let lastModified: Date?

    @Published var folderSize: Int64 = -1
    @Published var items: [UninstallItem] = []
    @Published var detailsLoaded = false
    @Published var isLoadingDetails = false
    @Published var git = GitStatus()
    @Published private(set) var linkedApp: AppInfo?
    private var linkedAppSub: AnyCancellable?

    init(name: String, url: URL, kinds: [String], lastModified: Date?) {
        self.name = name
        self.url = url
        self.kinds = kinds
        self.lastModified = lastModified
    }

    func setLinkedApp(_ app: AppInfo?) {
        linkedApp = app
        // Re-publish the app's changes (its sizes load lazily) so views of the project update too
        linkedAppSub = app?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var icon: NSImage { linkedApp?.icon ?? NSWorkspace.shared.icon(forFile: url.path) }

    /// Project folder + things outside it (DerivedData, installed app and its data).
    var totalSize: Int64 {
        let outside = uninstallItems.filter { item in !item.paths.allSatisfy { isInside($0, url) } }
        return max(folderSize, 0) + topLevelItems(outside).reduce(0) { $0 + max($1.size, 0) }
    }

    static func == (lhs: ProjectInfo, rhs: ProjectInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ProjectInfo: UninstallTarget {
    var displayName: String { name }
    var iconImage: NSImage? { icon }
    var uninstallItems: [UninstallItem] { items + (linkedApp?.uninstallItems ?? []) }
    var uninstallModes: [UninstallMode] { [.everything, .keepData, .buildOnly] }
    var runningBundleIDs: [String] { linkedApp?.runningBundleIDs ?? [] }
    var referenceKeywords: [String] { [] }
    var containerFolder: URL? { url }
    var warnings: [String] { git.warnings }
    var relatedAppIDs: Set<UUID> { linkedApp.map { Set([$0.id]) } ?? Set<UUID>() }
}

// MARK: - ProjectScanner

final class ProjectScanner: ObservableObject {
    @Published var projects: [ProjectInfo] = []
    @Published var isScanning = false
    @Published private(set) var roots: [URL] = []

    private static let rootsKey = "projectRoots"
    private let fm = FileManager.default
    private var scanGeneration = 0

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.rootsKey) {
            roots = saved.map { URL(fileURLWithPath: $0) }
        } else {
            let def = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Projects_Folder")
            roots = fm.fileExists(atPath: def.path) ? [def] : []
        }
        updateProtected()
    }

    // MARK: Roots

    func addRoots(_ urls: [URL]) {
        for u in urls where !roots.contains(u) { roots.append(u) }
        saveRoots()
        scan()
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
        saveRoots()
        scan()
    }

    private func saveRoots() {
        UserDefaults.standard.set(roots.map(\.path), forKey: Self.rootsKey)
        updateProtected()
    }

    private func updateProtected() {
        // Never let a whole projects folder be trashed by accident
        AppScanner.extraProtectedPaths = Set(roots.map { $0.standardizedFileURL.path })
    }

    func removeProject(_ project: ProjectInfo) {
        projects.removeAll { $0.id == project.id }
    }

    // MARK: Scan

    func scan() {
        scanGeneration += 1
        let generation = scanGeneration
        let roots = self.roots
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [ProjectInfo] = []
            var seen = Set<String>()
            for root in roots {
                for dir in self.subdirectories(of: root) {
                    let kinds = self.detectKinds(dir)
                    if !kinds.isEmpty {
                        if seen.insert(dir.path).inserted { found.append(self.makeProject(dir, kinds)) }
                    } else {
                        // A plain folder that groups projects (e.g. Projects_Folder/Clients/…)
                        for sub in self.subdirectories(of: dir) {
                            let k = self.detectKinds(sub)
                            if !k.isEmpty, seen.insert(sub.path).inserted { found.append(self.makeProject(sub, k)) }
                        }
                    }
                }
            }
            found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                guard generation == self.scanGeneration else { return }
                self.projects = found
                self.isScanning = false
            }
            // Folder sizes, one by one in the background
            for p in found {
                let size = diskUsage(p.url)
                DispatchQueue.main.async { p.folderSize = size }
            }
        }
    }

    private func subdirectories(of url: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }
    }

    private func makeProject(_ url: URL, _ kinds: [String]) -> ProjectInfo {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return ProjectInfo(name: url.lastPathComponent, url: url, kinds: kinds, lastModified: modified)
    }

    func detectKinds(_ dir: URL) -> [String] {
        let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        var kinds: [String] = []
        func has(_ n: String...) -> Bool { n.contains { names.contains($0) } }
        if has("Package.swift") { kinds.append("Swift") }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { kinds.append("Xcode") }
        if has("package.json") { kinds.append("Node") }
        if has("pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "environment.yml") ||
            names.contains(where: { $0.hasSuffix(".ipynb") }) { kinds.append("Python") }
        if has("Cargo.toml") { kinds.append("Rust") }
        if has("go.mod") { kinds.append("Go") }
        if has("pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts") { kinds.append("Java/Android") }
        if has("pubspec.yaml") { kinds.append("Flutter") }
        if has("Gemfile") { kinds.append("Ruby") }
        if has("CMakeLists.txt") { kinds.append("C/C++") }
        if has("docker-compose.yml", "docker-compose.yaml", "compose.yaml", "Dockerfile") { kinds.append("Docker") }
        if has(".git") { kinds.append("Git") }
        return kinds
    }

    // MARK: Details (what can be removed)

    /// Folders that are rebuilt automatically — always safe to delete.
    static let buildNames: Set<String> = [
        ".build", "build", "dist", "out", "target", "node_modules", ".venv", "venv", "__pycache__", ".next",
        ".nuxt", ".svelte-kit", ".gradle", "Pods", ".dart_tool", ".swiftpm", ".pytest_cache", ".mypy_cache",
        ".ruff_cache", ".tox", ".parcel-cache", ".turbo", "coverage", "DerivedData", ".expo", ".angular",
        "cmake-build-debug", "cmake-build-release", ".cache", ".ipynb_checkpoints", "xcuserdata",
    ]
    /// Folder names that hold models or data. Generous on purpose: when unsure, "Keep Models & Data" keeps it.
    static let dataNames: Set<String> = [
        "models", "model", "weights", "checkpoints", "ckpt", "data", "datasets", "dataset", "embeddings",
        "vectorstore", "vector_store", "vectordb", "chroma", "chroma_db", "chromadb", "faiss_index", "lancedb",
        "qdrant_storage", "outputs", "output", "runs", "wandb", "mlruns", "lightning_logs", "db", "database",
        "uploads", "media", "storage", "samples", "pretrained", "hf_cache", "huggingface", "ollama",
    ]
    static let modelExtensions: Set<String> = [
        "gguf", "ggml", "safetensors", "pt", "pth", "bin", "onnx", "ckpt", "h5", "keras", "tflite", "mlmodel",
        "mlpackage", "mlmodelc", "pkl", "joblib", "npy", "npz", "parquet", "feather", "arrow", "sqlite",
        "sqlite3", "db", "faiss", "csv", "tsv", "jsonl", "lance",
    ]

    func loadDetails(_ project: ProjectInfo, appScanner: AppScanner, force: Bool = false) {
        guard force || (!project.detailsLoaded && !project.isLoadingDetails) else { return }
        project.isLoadingDetails = true

        // Installed copy of this project (e.g. SpaceUtilizer.app in /Applications)
        let key = project.name.lowercased().filter { $0.isLetter || $0.isNumber }
        let linked = appScanner.apps.first { $0.name.lowercased().filter { $0.isLetter || $0.isNumber } == key }
        project.setLinkedApp(linked)
        if let linked { appScanner.computeSizesIfNeeded(for: linked) }

        DispatchQueue.global(qos: .userInitiated).async {
            let items = self.classify(project)
            let git = self.gitStatus(project.url)
            DispatchQueue.main.async {
                project.items = items
                project.git = git
                project.detailsLoaded = true
                project.isLoadingDetails = false
            }
            for item in items {
                let size = item.paths.reduce(Int64(0)) { $0 + diskUsage($1) }
                DispatchQueue.main.async {
                    if let i = project.items.firstIndex(where: { $0.id == item.id }) { project.items[i].size = size }
                }
            }
            let folder = diskUsage(project.url)
            DispatchQueue.main.async { project.folderSize = folder }
        }
    }

    private func classify(_ project: ProjectInfo) -> [UninstallItem] {
        let children = (try? fm.contentsOfDirectory(at: project.url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                     options: [])) ?? []
        var build: [URL] = []
        var data: [URL] = []
        var source: [URL] = []

        for child in children {
            let name = child.lastPathComponent
            if name == ".DS_Store" { source.append(child); continue }
            if isDirectory(child) {
                if Self.buildNames.contains(name) || fm.fileExists(atPath: child.appendingPathComponent("pyvenv.cfg").path) {
                    build.append(child)
                } else if Self.dataNames.contains(name.lowercased()) {
                    data.append(child)
                } else {
                    source.append(child)
                }
            } else if isDataFile(child) {
                data.append(child)
            } else {
                source.append(child)
            }
        }

        // Models/data nested deeper inside source folders (e.g. app/assets/models/llama.gguf)
        var nested: [URL] = []
        for dir in source where isDirectory(dir) && dir.lastPathComponent != ".git" {
            nested += findNestedData(in: dir)
        }
        data += nested
        // Source = everything else, carved around the nested data so it can be kept
        let sourcePaths = source.flatMap { carve($0, keeping: nested) }

        var items: [UninstallItem] = []
        if !sourcePaths.isEmpty {
            let hasGit = source.contains { $0.lastPathComponent == ".git" }
            items.append(UninstallItem(title: "Source Code & Project Files", paths: sourcePaths,
                                       detail: "\(source.count) files and folders" + (hasGit ? ", including git history" : ""),
                                       icon: "chevron.left.forwardslash.chevron.right", group: .sourceCode, size: -1))
        }
        for b in build {
            items.append(UninstallItem(title: b.lastPathComponent, path: b, detail: buildDescription(b.lastPathComponent),
                                       icon: "hammer.fill", group: .buildArtifacts, size: -1))
        }
        for d in data {
            let isModel = Self.modelExtensions.contains(d.pathExtension.lowercased())
                || ["models", "model", "weights", "checkpoints", "pretrained"].contains(d.lastPathComponent.lowercased())
            items.append(UninstallItem(title: d.lastPathComponent, path: d,
                                       detail: isModel ? "Model files inside the project" : "Data inside the project",
                                       icon: isModel ? "cube.fill" : "externaldrive.fill", group: .appData, size: -1))
        }

        // Xcode DerivedData lives outside the project: ~/Library/Developer/Xcode/DerivedData/<Name>-<hash>
        let derived = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData")
        if let entries = try? fm.contentsOfDirectory(at: derived, includingPropertiesForKeys: nil) {
            for e in entries where e.lastPathComponent.hasPrefix(project.name + "-") {
                items.append(UninstallItem(title: "Xcode DerivedData", path: e, detail: "Build cache for this project",
                                           icon: "hammer.fill", group: .buildArtifacts, size: -1))
            }
        }
        return items
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isDataFile(_ url: URL) -> Bool {
        if Self.modelExtensions.contains(url.pathExtension.lowercased()) { return true }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 200_000_000      // any file over 200 MB is almost certainly data
    }

    /// Model folders / big model files up to 4 levels down inside a source folder.
    private func findNestedData(in dir: URL) -> [URL] {
        let strongNames: Set<String> = ["models", "weights", "checkpoints", "datasets", "embeddings",
                                        "chroma_db", "vectorstore", "pretrained", "lancedb"]
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                    options: [.skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let name = url.lastPathComponent
            if v?.isDirectory == true {
                if Self.buildNames.contains(name) || name == ".git" || e.level > 4 {
                    e.skipDescendants()
                } else if strongNames.contains(name.lowercased()) {
                    found.append(url)
                    e.skipDescendants()
                }
            } else if Self.modelExtensions.contains(url.pathExtension.lowercased()), (v?.fileSize ?? 0) > 20_000_000 {
                found.append(url)
            } else if (v?.fileSize ?? 0) > 200_000_000 {
                found.append(url)
            }
        }
        return found
    }

    /// Paths that cover `url` except the `keeping` paths inside it.
    private func carve(_ url: URL, keeping: [URL]) -> [URL] {
        let inside = keeping.filter { isInside($0, url) }
        if inside.isEmpty { return [url] }
        if inside.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) { return [] }
        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
        return children.flatMap { carve($0, keeping: inside) }
    }

    private func buildDescription(_ name: String) -> String {
        switch name {
        case "node_modules": return "Node packages — `npm install` brings them back"
        case ".venv", "venv": return "Python virtual environment for this project — recreate with pip"
        case ".build", ".swiftpm": return "Swift build output"
        case "Pods": return "CocoaPods — `pod install` brings them back"
        case "target": return "Build output (Rust / Java)"
        case "dist", "build", "out": return "Build output"
        case "__pycache__": return "Python bytecode cache"
        default: return "Generated build/cache files"
        }
    }

    private func gitStatus(_ url: URL) -> GitStatus {
        var g = GitStatus()
        guard fm.fileExists(atPath: url.appendingPathComponent(".git").path) else { return g }
        g.isRepo = true
        // Only use git if developer tools are installed (otherwise macOS would show an install prompt)
        let hasTools = fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
            || fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        guard hasTools, let out = runProcess("/usr/bin/git", ["-C", url.path, "status", "--porcelain=v1", "-b"], timeout: 8) else {
            g.hasRemote = true   // unknown — don't raise a false alarm
            return g
        }
        let lines = out.split(separator: "\n")
        if let head = lines.first, head.hasPrefix("## ") {
            let h = head.dropFirst(3)
            g.branch = String(h.split(separator: ".").first ?? h)
            if let r = h.range(of: "ahead ") {
                g.ahead = Int(h[r.upperBound...].prefix { $0.isNumber }) ?? 0
            }
        }
        g.uncommitted = lines.dropFirst().filter { !$0.isEmpty }.count
        let remotes = runProcess("/usr/bin/git", ["-C", url.path, "remote"], timeout: 5) ?? ""
        g.hasRemote = !remotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return g
    }
}
