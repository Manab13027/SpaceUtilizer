import Foundation
import AppKit
import SwiftUI

// MARK: - AppInfo

final class AppInfo: ObservableObject, Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: URL
    let bundleID: String?
    let appSize: Int64
    let lastUsed: Date?
    let version: String?
    let icon: NSImage?
    @Published var associatedFiles: [AssociatedFile]
    @Published var dataFolders: [DataFolder]

    init(name: String, path: URL, bundleID: String?, appSize: Int64,
         lastUsed: Date?, version: String?, icon: NSImage?,
         associatedFiles: [AssociatedFile], dataFolders: [DataFolder] = []) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.appSize = appSize
        self.lastUsed = lastUsed
        self.version = version
        self.icon = icon
        self.associatedFiles = associatedFiles
        self.dataFolders = dataFolders
    }

    var totalSize: Int64 {
        let assoc = associatedFiles.reduce(0) { $0 + max($1.size, 0) }
        let data  = dataFolders.reduce(0)    { $0 + max($1.size, 0) }
        return appSize + assoc + data
    }

    var installLocation: String {
        if path.path.hasPrefix(NSHomeDirectory() + "/Applications") { return "~/Applications" }
        if path.path.hasPrefix("/Applications") { return "/Applications" }
        return path.deletingLastPathComponent().path
    }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - DataFolder

struct DataFolder: Identifiable {
    let id = UUID()
    let label: String
    let path: URL
    let description: String
    // -1 means "not yet computed" — size is calculated lazily off-main-thread
    var size: Int64

    var displayPath: String {
        path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - FileBrowserNode

final class FileBrowserNode: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let size: Int64

    @Published var children: [FileBrowserNode] = []
    @Published var isExpanded = false
    @Published var isLoaded = false

    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool, size: Int64) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
    }

    static func build(from url: URL) -> FileBrowserNode {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        // Never recursively walk directories here — that would freeze the UI.
        // Directories show size 0; files use the fast file-size attribute.
        let size: Int64 = isDir.boolValue
            ? 0
            : (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return FileBrowserNode(url: url, isDirectory: isDir.boolValue, size: size)
    }

    func expand() {
        guard isDirectory, !isLoaded else {
            isExpanded = true
            return
        }
        isExpanded = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(
                at: self.url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let sorted = items.sorted {
                let aDir = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bDir = (try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if aDir != bDir { return aDir }
                return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
            let nodes = sorted.map { FileBrowserNode.build(from: $0) }
            DispatchQueue.main.async {
                self.children = nodes
                self.isLoaded = true
            }
        }
    }
}

private func computeSize(_ url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    var total: Int64 = 0
    for case let f as URL in enumerator {
        guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              v.isRegularFile == true, let sz = v.fileSize else { continue }
        total += Int64(sz)
    }
    return total
}

// MARK: - AssociatedFile

struct AssociatedFile: Identifiable, Hashable {
    let id = UUID()
    let path: URL
    var size: Int64   // -1 = not yet computed
    let category: FileCategory

    var name: String { path.lastPathComponent }
    var displayPath: String {
        path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - FileCategory

enum FileCategory: String, CaseIterable {
    case preferences = "Preferences"
    case cache       = "Cache"
    case support     = "App Support"
    case logs        = "Logs"
    case containers  = "Containers"
    case launchAgents = "Launch Agents"
    case other       = "Other"

    var systemImage: String {
        switch self {
        case .preferences:  return "gearshape.fill"
        case .cache:        return "internaldrive.fill"
        case .support:      return "folder.fill"
        case .logs:         return "doc.text.fill"
        case .containers:   return "shippingbox.fill"
        case .launchAgents: return "terminal.fill"
        case .other:        return "questionmark.folder.fill"
        }
    }

    var color: Color {
        switch self {
        case .preferences:  return .blue
        case .cache:        return .orange
        case .support:      return .green
        case .logs:         return .secondary
        case .containers:   return .purple
        case .launchAgents: return .red
        case .other:        return .gray
        }
    }

    var explanation: String {
        switch self {
        case .preferences:  return "Settings & configs — ~/Library/Preferences"
        case .cache:        return "Temporary data — ~/Library/Caches (safe to delete)"
        case .support:      return "App data & databases — ~/Library/Application Support"
        case .logs:         return "Log files — ~/Library/Logs (safe to delete)"
        case .containers:   return "Sandboxed app data — ~/Library/Containers"
        case .launchAgents: return "Background auto-start processes — ~/Library/LaunchAgents"
        case .other:        return "Other associated files"
        }
    }

    var isSafeToDelete: Bool { self == .cache || self == .logs }
}
