import Foundation
import AppKit

// MARK: - Reason

/// Why an item should probably be kept: something else uses it.
struct UsageReason: Hashable, Identifiable {
    enum Kind: Hashable { case app, project, link, process }
    let kind: Kind
    let name: String
    let detail: String

    var id: String { "\(kind)|\(name)|\(detail)" }

    var icon: String {
        switch kind {
        case .app:     return "app.badge"
        case .project: return "folder.fill"
        case .link:    return "link"
        case .process: return "gearshape.2.fill"
        }
    }

    var sentence: String { "\(name) \(detail)" }
}

// MARK: - Context (snapshot of everything else on the Mac)

/// A thread-safe snapshot of the other apps and projects, taken on the main thread.
struct UsageContext {
    struct OwnerApp {
        let name: String
        /// Library files + data folders (not the .app bundle).
        let paths: [String]
        /// Only the known data folders (models, VMs…) — scanned for symlinks.
        let dataPaths: [String]
    }
    struct OwnerProject {
        let name: String
        let root: URL
    }

    var apps: [OwnerApp] = []
    var installedAppNames: Set<String> = []
    var projects: [OwnerProject] = []

    static func make(apps: [AppInfo], projects: [ProjectInfo],
                     excludingApps: Set<UUID>, excludingProject: URL?) -> UsageContext {
        var c = UsageContext()
        c.installedAppNames = Set(apps.map { $0.name.lowercased() })
        c.apps = apps.filter { !excludingApps.contains($0.id) }.map { app in
            OwnerApp(name: app.name,
                     paths: app.associatedFiles.map { $0.path.standardizedFileURL.path }
                          + app.dataFolders.map { $0.path.standardizedFileURL.path },
                     dataPaths: app.dataFolders.map { $0.path.standardizedFileURL.path })
        }
        c.projects = projects
            .filter { p in excludingProject.map { !isInside(p.url, $0) && !isInside($0, p.url) } ?? true }
            .map { OwnerProject(name: $0.name, root: $0.url) }
        return c
    }
}

// MARK: - Checker

enum UsageChecker {

    /// Apps that are known to use another app's models. Key = lowercased provider app name.
    static let knownConsumers: [String: [String]] = [
        "ollama":    ["Enchanted", "Ollamac", "Msty", "BoltAI", "AnythingLLM", "Chatbox", "Witsy", "Reor",
                      "Open WebUI", "Ollama App", "Jan", "Raycast", "Elephas", "MindMac"],
        "lm studio": ["AnythingLLM", "Msty", "BoltAI", "Chatbox", "Witsy", "Jan", "Elephas", "MindMac"],
    ]

    /// Folders never searched inside projects (too big or not written by you).
    private static let skipDirs: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "out", "target", ".venv", "venv", "env", "__pycache__",
        "Pods", "DerivedData", ".gradle", ".next", ".nuxt", ".dart_tool", ".swiftpm", ".tox", ".mypy_cache",
        ".pytest_cache", ".ruff_cache", "models", "weights", "checkpoints", "datasets", "data", ".cache",
    ]
    private static let linkSkipDirs: Set<String> = [
        ".git", "node_modules", ".build", "Pods", "DerivedData", "__pycache__", ".venv", "venv", ".gradle",
    ]
    private static let textExtensions: Set<String> = [
        "py", "ipynb", "js", "mjs", "cjs", "ts", "tsx", "jsx", "swift", "json", "toml", "yaml", "yml", "txt",
        "cfg", "ini", "env", "sh", "zsh", "go", "rs", "java", "kt", "rb", "php", "cs", "cpp", "c", "h", "m",
        "gradle", "kts", "xml", "plist", "conf", "lock", "md",
    ]
    private static let textFileNames: Set<String> = [
        "dockerfile", "makefile", "procfile", "gemfile", "podfile", ".env", "modelfile",
    ]
    /// System helpers that briefly touch files (indexing, previews) — not real users.
    private static let ignoredProcesses: Set<String> = [
        "mds", "mds_stores", "mdworker", "mdworker_shared", "fseventsd", "Finder", "QuickLookSatellite",
        "quicklookd", "revisiond", "bird", "cloudd", "backupd", "lsof", "SpaceUtilizer",
    ]

    struct Request {
        let items: [UninstallItem]
        let ownerName: String
        let keywords: [String]
        let container: URL?
        let ownBundleIDs: [String]
        /// .app bundles of the target — its own helper processes don't count as "other".
        let ownAppPaths: [String]
        let context: UsageContext
    }

    /// Checks models/data (and, for projects, the source) for other users.
    /// Calls `completion` on the main thread with reasons per item ID.
    static func check(_ req: Request, completion: @escaping ([UUID: [UsageReason]]) -> Void) {
        let candidates = req.items.filter { $0.group.isData || $0.group == .sourceCode }
        guard !candidates.isEmpty else {
            DispatchQueue.main.async { completion([:]) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var result: [UUID: [UsageReason]] = [:]
            func add(_ id: UUID, _ r: UsageReason) {
                if !(result[id]?.contains(r) ?? false) { result[id, default: []].append(r) }
            }

            let dataItems = candidates.filter { $0.group.isData }
            let sourceItems = candidates.filter { $0.group == .sourceCode }
            let resolved: [(UUID, [String])] = dataItems.map {
                ($0.id, $0.paths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
            }

            // 1. Other apps that keep data in the same place (e.g. Xcode + Simulator, Logic + GarageBand)
            for owner in req.context.apps {
                for op in owner.paths {
                    for (id, paths) in resolved where paths.contains(where: { overlaps($0, op) }) {
                        add(id, UsageReason(kind: .app, name: owner.name, detail: "also keeps its data here"))
                    }
                }
            }

            // 2. Installed apps known to use this app's models (e.g. Msty / Enchanted use Ollama's models)
            if let consumers = knownConsumers[req.ownerName.lowercased()] {
                for c in consumers where req.context.installedAppNames.contains(c.lowercased()) {
                    for item in dataItems where item.group == .appData {
                        add(item.id, UsageReason(kind: .app, name: c, detail: "can use \(req.ownerName)'s models"))
                    }
                }
            }

            // 3. Your projects that refer to these folders or use this app
            var pathTokens: [UUID: [String]] = [:]
            for item in dataItems {
                pathTokens[item.id] = item.paths.flatMap { tokens(for: $0) }
            }
            if let container = req.container {
                let name = container.lastPathComponent.lowercased()
                let rel = ["../\(name)/", "../\(name)\"", "../\(name)'", "../\(name)\n"]
                for item in sourceItems { pathTokens[item.id] = tokens(for: container) + rel }
            }
            let keywords = req.keywords.map { $0.lowercased() }

            for project in req.context.projects {
                var pathHits: [UUID: Set<String>] = [:]
                var keywordHits: [String: Set<String>] = [:]
                enumerateTextFiles(in: project.root) { rel, text in
                    for (id, toks) in pathTokens where toks.contains(where: { text.contains($0) }) {
                        pathHits[id, default: []].insert(rel)
                    }
                    for kw in keywords where usesAsDependency(text, kw, fileName: (rel as NSString).lastPathComponent) {
                        keywordHits[kw, default: []].insert(rel)
                    }
                }
                for (id, files) in pathHits {
                    add(id, UsageReason(kind: .project, name: project.name,
                                        detail: "refers to this in \(fileList(files))"))
                }
                if let kw = keywordHits.keys.sorted().first, let files = keywordHits[kw] {
                    for item in dataItems where item.group == .appData {
                        add(item.id, UsageReason(kind: .project, name: project.name,
                                                 detail: "uses \(kw) (\(fileList(files)))"))
                    }
                }
            }

            // 4. Symlinks elsewhere pointing into these folders (e.g. models linked into another app)
            var linkRoots: [(String, URL)] = []
            for owner in req.context.apps { for p in owner.dataPaths { linkRoots.append((owner.name, URL(fileURLWithPath: p))) } }
            for project in req.context.projects { linkRoots.append((project.name, project.root)) }
            for (name, root) in linkRoots {
                findSymlinks(in: root) { link, dest in
                    for (id, paths) in resolved where paths.contains(where: { dest == $0 || dest.hasPrefix($0 + "/") }) {
                        add(id, UsageReason(kind: .link, name: name, detail: "links to it from \(tildePath(link))"))
                    }
                }
            }

            // 5. Programs that have files open there right now
            var ownPIDs = Set<Int32>([getpid()])
            for bid in req.ownBundleIDs {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                    ownPIDs.insert(app.processIdentifier)
                }
            }
            var lsofTargets: [(UUID, URL)] = []
            for item in dataItems { for p in item.paths { lsofTargets.append((item.id, p)) } }
            if let container = req.container { for item in sourceItems { lsofTargets.append((item.id, container)) } }
            for (id, url) in lsofTargets {
                for proc in openFileProcesses(url) where !ownPIDs.contains(proc.pid) {
                    // lsof shortens long names, so compare by prefix
                    if ignoredProcesses.contains(where: { proc.command.hasPrefix($0)
                        || (proc.command.count >= 12 && $0.hasPrefix(proc.command)) }) { continue }
                    if req.ownAppPaths.contains(where: { proc.executable.hasPrefix($0 + "/") }) { continue }
                    add(id, UsageReason(kind: .process, name: proc.command,
                                        detail: "has files open here right now (pid \(proc.pid))"))
                }
            }

            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: Helpers

    private static func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    /// Lowercased ways a path can appear in a file: absolute, ~/…, $HOME/…
    private static func tokens(for url: URL) -> [String] {
        let p = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        var t = [p.lowercased()]
        if p.hasPrefix(home + "/") {
            let rest = String(p.dropFirst(home.count))           // "/.ollama/models"
            t.append(("~" + rest).lowercased())
            t.append(("$home" + rest).lowercased())
            t.append(("${home}" + rest).lowercased())
            // Hidden home folders are usually written as "/.ollama" in code
            let first = rest.split(separator: "/").first.map(String.init) ?? ""
            if first.hasPrefix("."), first.count >= 5, rest == "/" + first {
                t.append(("/" + first + "/").lowercased())
                t.append(("/" + first + "\"").lowercased())
                t.append(("/" + first + "'").lowercased())
            }
        }
        return t
    }

    /// The keyword appears as a dependency (requirements.txt, package.json, compose files, .env…)
    /// or on an import/require line in code — not just anywhere (e.g. "cursor" in database code).
    private static func usesAsDependency(_ text: String, _ kw: String, fileName: String) -> Bool {
        guard text.contains(kw) else { return false }
        let f = fileName.lowercased()
        let dependencyFiles: Set<String> = [
            "pyproject.toml", "setup.py", "setup.cfg", "pipfile", "environment.yml", "environment.yaml",
            "package.json", "package.swift", "podfile", "gemfile", "cargo.toml", "go.mod", "modelfile",
        ]
        let isDependencyFile = dependencyFiles.contains(f)
            || (f.hasPrefix("requirements") && f.hasSuffix(".txt"))
            || f.hasPrefix("docker-compose") || f.hasPrefix("compose.") || f.hasPrefix(".env")
        if isDependencyFile { return containsWord(text, kw) }
        for line in text.split(separator: "\n") where line.contains(kw) {
            let l = line.trimmingCharacters(in: .whitespaces)
            let isImport = l.hasPrefix("import ") || l.hasPrefix("from ") || l.contains("require(")
                || l.hasPrefix("use ") || l.hasPrefix("@import")
            if isImport && containsWord(String(l), kw) { return true }
        }
        return false
    }

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: word, range: searchRange) {
            let beforeOK = r.lowerBound == text.startIndex || !isWordChar(text[text.index(before: r.lowerBound)])
            let afterOK = r.upperBound == text.endIndex || !isWordChar(text[r.upperBound])
            if beforeOK && afterOK { return true }
            searchRange = r.upperBound..<text.endIndex
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func fileList(_ files: Set<String>) -> String {
        let sorted = files.sorted()
        let shown = sorted.prefix(2).joined(separator: ", ")
        return sorted.count > 2 ? shown + " +\(sorted.count - 2) more" : shown
    }

    private static func enumerateTextFiles(in root: URL, _ body: (String, String) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsPackageDescendants]) else { return }
        var count = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if v?.isDirectory == true {
                if skipDirs.contains(name) || e.level > 5 { e.skipDescendants() }
                continue
            }
            let lower = name.lowercased()
            guard textExtensions.contains(url.pathExtension.lowercased())
                    || textFileNames.contains(lower) || lower.hasPrefix(".env") else { continue }
            guard (v?.fileSize ?? 0) <= 400_000, let data = try? Data(contentsOf: url) else { continue }
            let rel = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            body(rel, String(decoding: data, as: UTF8.self).lowercased())
            count += 1
            if count >= 4000 { break }
        }
    }

    private static func findSymlinks(in root: URL, _ body: (String, String) -> Void) {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsPackageDescendants]) else { return }
        var count = 0
        for case let url as URL in e {
            count += 1
            if count > 20_000 { break }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true {
                body(url.path, url.resolvingSymlinksInPath().path)
            } else if v?.isDirectory == true, linkSkipDirs.contains(url.lastPathComponent) || e.level > 4 {
                e.skipDescendants()
            }
        }
    }

    private struct OpenFileProcess { let pid: Int32; let command: String; let executable: String }

    /// Processes with files open inside `url` (uses lsof; gives up after a few seconds on huge folders).
    private static func openFileProcesses(_ url: URL) -> [OpenFileProcess] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        let args = isDir.boolValue ? ["-w", "-Fpc", "+D", url.path] : ["-w", "-Fpc", url.path]
        guard let out = runProcess("/usr/sbin/lsof", args, timeout: 6) else { return [] }

        var found: [Int32: String] = [:]
        var currentPID: Int32?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { currentPID = Int32(line.dropFirst()) }
            else if line.hasPrefix("c"), let pid = currentPID { found[pid] = String(line.dropFirst()) }
        }
        guard !found.isEmpty else { return [] }

        // Full executable paths, to recognise the app's own helpers
        var exe: [Int32: String] = [:]
        let pids = found.keys.map(String.init).joined(separator: ",")
        if let ps = runProcess("/bin/ps", ["-o", "pid=,comm=", "-p", pids], timeout: 3) {
            for line in ps.split(separator: "\n") {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                if parts.count == 2, let pid = Int32(parts[0]) { exe[pid] = String(parts[1]) }
            }
        }
        return found.map { OpenFileProcess(pid: $0.key, command: $0.value, executable: exe[$0.key] ?? "") }
    }
}
