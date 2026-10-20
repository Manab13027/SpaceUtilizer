import SwiftUI
import AppKit

// MARK: - Item groups

/// How a removable item relates to its app or project. Drives defaults and the section it is shown in.
enum ItemGroup: Int, CaseIterable {
    case application, sourceCode, buildArtifacts, libraryFiles, appData, userContent, sharedLibrary

    var title: String {
        switch self {
        case .application:    return "Application"
        case .sourceCode:     return "Source Code & Project Files"
        case .buildArtifacts: return "Build Files & Dependencies"
        case .libraryFiles:   return "Settings, Caches & Support Files"
        case .appData:        return "Models & App Data"
        case .userContent:    return DataKind.userContent.title
        case .sharedLibrary:  return DataKind.sharedLibrary.title
        }
    }

    var subtitle: String? {
        switch self {
        case .application:    return nil
        case .sourceCode:     return "Your code, configs and git history."
        case .buildArtifacts: return "node_modules, virtual envs, .build, DerivedData… Recreated on the next build."
        case .libraryFiles:   return "Files the app created in ~/Library."
        case .appData:        return "Downloaded models, datasets, caches and data."
        case .userContent:    return DataKind.userContent.explanation
        case .sharedLibrary:  return DataKind.sharedLibrary.explanation
        }
    }

    var color: Color {
        switch self {
        case .application:    return .blue
        case .sourceCode:     return .indigo
        case .buildArtifacts: return .brown
        case .libraryFiles:   return .orange
        case .appData:        return DataKind.appData.color
        case .userContent:    return DataKind.userContent.color
        case .sharedLibrary:  return DataKind.sharedLibrary.color
        }
    }

    /// Models, data and content — what "Keep Models & Data" leaves in place.
    var isData: Bool { self == .appData || self == .userContent || self == .sharedLibrary }

    static func from(_ kind: DataKind) -> ItemGroup {
        switch kind {
        case .appData:       return .appData
        case .userContent:   return .userContent
        case .sharedLibrary: return .sharedLibrary
        }
    }
}

// MARK: - Item

/// One removable thing. Usually one path; "Source Code" of a project can be several
/// sibling paths (everything in the project except the models/data being kept).
struct UninstallItem: Identifiable {
    let id: UUID
    let title: String
    let paths: [URL]
    let detail: String
    let icon: String
    let group: ItemGroup
    var size: Int64          // -1 = still calculating

    init(id: UUID = UUID(), title: String, paths: [URL], detail: String,
         icon: String, group: ItemGroup, size: Int64) {
        self.id = id; self.title = title; self.paths = paths; self.detail = detail
        self.icon = icon; self.group = group; self.size = size
    }

    init(id: UUID = UUID(), title: String, path: URL, detail: String,
         icon: String, group: ItemGroup, size: Int64) {
        self.init(id: id, title: title, paths: [path], detail: detail, icon: icon, group: group, size: size)
    }

    var path: URL { paths.first ?? URL(fileURLWithPath: "/") }

    var displayPath: String {
        if paths.count > 1 {
            return "\(paths.count) items in " + tildePath(path.deletingLastPathComponent().path)
        }
        return tildePath(path.path)
    }
}

// MARK: - Modes

enum UninstallMode: String, CaseIterable, Identifiable {
    case everything, keepData, appOnly, buildOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everything: return "Everything"
        case .keepData:   return "Keep Models & Data"
        case .appOnly:    return "App Only"
        case .buildOnly:  return "Build Files Only"
        }
    }

    var explanation: String {
        switch self {
        case .everything: return "Removes everything except your own content, shared libraries and anything other apps or projects still use."
        case .keepData:   return "Removes the app/code and its settings, caches and build files. Models and data stay where they are."
        case .appOnly:    return "Removes only the application. Settings, models and data stay."
        case .buildOnly:  return "Frees space by removing build output and dependencies. Your project stays and can be rebuilt."
        }
    }

    func includesByDefault(_ g: ItemGroup) -> Bool {
        switch self {
        case .everything: return g != .userContent && g != .sharedLibrary
        case .keepData:   return !g.isData
        case .appOnly:    return g == .application
        case .buildOnly:  return g == .buildArtifacts
        }
    }
}

// MARK: - Target protocol (apps and projects)

protocol UninstallTarget: ObservableObject {
    var displayName: String { get }
    var iconImage: NSImage? { get }
    var uninstallItems: [UninstallItem] { get }
    var uninstallModes: [UninstallMode] { get }
    /// Bundle IDs that must not be running while uninstalling.
    var runningBundleIDs: [String] { get }
    /// Words that, found in a project's files, mean the project uses this app's data (e.g. "ollama").
    var referenceKeywords: [String] { get }
    /// For projects: the project folder. If everything inside is selected, the folder itself is trashed.
    var containerFolder: URL? { get }
    /// Shown when source code is about to be removed (e.g. uncommitted git changes).
    var warnings: [String] { get }
    /// Apps that belong to this target (excluded from "used by other apps").
    var relatedAppIDs: Set<UUID> { get }
}

extension UninstallTarget {
    func defaultSelection(for mode: UninstallMode) -> Set<UUID> {
        Set(uninstallItems.filter { mode.includesByDefault($0.group) }.map(\.id))
    }

    func size(of ids: Set<UUID>) -> Int64 {
        topLevelItems(uninstallItems.filter { ids.contains($0.id) }).reduce(0) { $0 + max($1.size, 0) }
    }
}

// MARK: - AppInfo as a target

extension AppInfo: UninstallTarget {
    var displayName: String { name }
    var iconImage: NSImage? { icon }

    var uninstallItems: [UninstallItem] {
        var items: [UninstallItem] = [
            UninstallItem(id: id, title: "\(name).app", path: path, detail: installLocation,
                          icon: "app.fill", group: .application, size: appSize)
        ]
        items += associatedFiles.map {
            UninstallItem(id: $0.id, title: $0.name, path: $0.path, detail: $0.category.rawValue,
                          icon: $0.category.systemImage, group: .libraryFiles, size: $0.size)
        }
        items += dataFolders.map {
            UninstallItem(id: $0.id, title: $0.label, path: $0.path, detail: $0.description,
                          icon: $0.kind.systemImage, group: .from($0.kind), size: $0.size)
        }
        return items
    }

    var uninstallModes: [UninstallMode] { [.everything, .keepData, .appOnly] }
    var runningBundleIDs: [String] { bundleID.map { [$0] } ?? [] }

    var referenceKeywords: [String] {
        let low = name.lowercased()
        let words = [low, low.replacingOccurrences(of: " ", with: "")]
        var seen = Set<String>()
        return words.filter { $0.count >= 4 && seen.insert($0).inserted }
    }

    var containerFolder: URL? { nil }
    var warnings: [String] { [] }
    var relatedAppIDs: Set<UUID> { [id] }
}

// MARK: - Path helpers

/// True if `child` is `parent` or inside it.
func isInside(_ child: URL, _ parent: URL) -> Bool {
    let c = child.standardizedFileURL.path
    let p = parent.standardizedFileURL.path
    return c == p || c.hasPrefix(p + "/")
}

/// Drops items whose paths all sit inside another item's path (e.g. Docker's VM folder
/// inside its container) so they are not counted or trashed twice.
func topLevelItems(_ items: [UninstallItem]) -> [UninstallItem] {
    let all: [(UUID, String)] = items.flatMap { item in item.paths.map { (item.id, $0.standardizedFileURL.path) } }
    return items.filter { item in
        let mine = item.paths.map { $0.standardizedFileURL.path }
        let nested = mine.allSatisfy { p in all.contains { $0.0 != item.id && p.hasPrefix($0.1 + "/") } }
        return !nested
    }
}
