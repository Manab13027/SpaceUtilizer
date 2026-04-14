import SwiftUI
import AppKit

// MARK: - Window opener

func openFileBrowserWindow(scanner: AppScanner) {
    let existing = NSApp.windows.first { $0.title == "File Browser" }
    if let existing {
        existing.makeKeyAndOrderFront(nil)
        return
    }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.title = "File Browser"
    window.center()
    window.minSize = NSSize(width: 700, height: 450)
    window.contentView = NSHostingView(rootView: FileBrowserWindowView(scanner: scanner))
    window.makeKeyAndOrderFront(nil)
}

// MARK: - Root locations

struct FSLocation: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let icon: String
    let color: Color

    var url: URL { URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appendingPathComponent(path.hasPrefix("~")
                            ? NSHomeDirectory() + path.dropFirst()
                            : path)
    }

    var resolvedURL: URL {
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: NSHomeDirectory() + path.dropFirst())
        }
        return URL(fileURLWithPath: path)
    }
}

let fsLocations: [FSLocation] = [
    FSLocation(name: "Home",         path: "~",                  icon: "house.fill",           color: .blue),
    FSLocation(name: "Desktop",      path: "~/Desktop",           icon: "menubar.rectangle",    color: .teal),
    FSLocation(name: "Documents",    path: "~/Documents",         icon: "doc.fill",             color: .blue),
    FSLocation(name: "Downloads",    path: "~/Downloads",         icon: "arrow.down.circle.fill",color: .green),
    FSLocation(name: "Applications", path: "/Applications",       icon: "square.grid.2x2.fill", color: .indigo),
    FSLocation(name: "Movies",       path: "~/Movies",            icon: "film.fill",            color: .red),
    FSLocation(name: "Music",        path: "~/Music",             icon: "music.note",           color: .pink),
    FSLocation(name: "Pictures",     path: "~/Pictures",          icon: "photo.fill",           color: .orange),
    FSLocation(name: "Library",      path: "~/Library",           icon: "books.vertical.fill",  color: .purple),
    FSLocation(name: "Macintosh HD", path: "/",                   icon: "internaldrive.fill",   color: .gray),
]

// MARK: - Main window view

struct FileBrowserWindowView: View {
    let scanner: AppScanner
    @StateObject private var state = FileBrowserState()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // Sidebar — location picker
            List(selection: $state.selectedLocation) {
                Section("Favorites") {
                    ForEach(fsLocations.dropLast()) { loc in
                        Label {
                            Text(loc.name)
                        } icon: {
                            Image(systemName: loc.icon).foregroundStyle(loc.color)
                        }
                        .tag(loc.id)
                        .onTapGesture { state.navigate(to: loc.resolvedURL, title: loc.name) }
                    }
                }
                Section("Device") {
                    ForEach(fsLocations.suffix(1)) { loc in
                        Label {
                            Text(loc.name)
                        } icon: {
                            Image(systemName: loc.icon).foregroundStyle(loc.color)
                        }
                        .tag(loc.id)
                        .onTapGesture { state.navigate(to: loc.resolvedURL, title: loc.name) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Locations")
        } detail: {
            FSTreeView(state: state, scanner: scanner)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(state.history.count <= 1)
                .help("Back")
            }
            ToolbarItem {
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.currentTitle)
                        .font(.headline)
                    Text(state.currentURL?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - State

final class FileBrowserState: ObservableObject {
    @Published var currentURL: URL? = URL(fileURLWithPath: NSHomeDirectory())
    @Published var currentTitle: String = "Home"
    @Published var history: [(url: URL, title: String)] = []
    @Published var selectedLocation: UUID? = fsLocations.first?.id
    @Published var nodes: [FSNode] = []
    @Published var isLoading = false
    @Published var sortBy: FSSortOption = .name
    @Published var showHidden = false

    private var loadToken = 0

    init() {
        navigate(to: URL(fileURLWithPath: NSHomeDirectory()), title: "Home")
    }

    func navigate(to url: URL, title: String) {
        if let current = currentURL {
            history.append((url: current, title: currentTitle))
        }
        currentURL = url
        currentTitle = title
        load(url: url)
    }

    func goBack() {
        guard !history.isEmpty else { return }
        let prev = history.removeLast()
        currentURL = prev.url
        currentTitle = prev.title
        load(url: prev.url)
    }

    func reload() {
        guard let url = currentURL else { return }
        load(url: url)
    }

    private func load(url: URL) {
        isLoading = true
        nodes = []
        loadToken += 1
        let token = loadToken
        // Capture published properties on main thread to avoid data races
        let showHidden = showHidden
        let sortBy = sortBy
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            let items = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentAccessDateKey,
                                              .creationDateKey, .isHiddenKey],
                options: opts
            )) ?? []

            var built = items.map { FSNode.build(from: $0) }
            built = Self.applySorting(built, by: sortBy)

            DispatchQueue.main.async {
                // Discard result if a newer load has started
                guard self.loadToken == token else { return }
                self.nodes = built
                self.isLoading = false
            }
        }
    }

    private static func applySorting(_ nodes: [FSNode], by sortBy: FSSortOption) -> [FSNode] {
        switch sortBy {
        case .name:
            return nodes.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .size:
            return nodes.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.size > $1.size
            }
        case .modified:
            return nodes.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }

    func sorted(_ nodes: [FSNode]) -> [FSNode] {
        Self.applySorting(nodes, by: sortBy)
    }

    func applySort() {
        nodes = sorted(nodes)
    }

    func toggleHidden() {
        showHidden.toggle()
        reload()
    }

    func remove(node: FSNode) {
        nodes.removeAll { $0.id == node.id }
    }
}

enum FSSortOption: String, CaseIterable {
    case name     = "Name"
    case size     = "Size"
    case modified = "Date Modified"
}

// MARK: - FSNode

final class FSNode: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    @Published var children: [FSNode] = []
    @Published var isExpanded = false
    @Published var isLoaded = false

    var name: String { url.lastPathComponent }
    var ext: String  { url.pathExtension.lowercased() }

    var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    init(url: URL, isDirectory: Bool, size: Int64, modified: Date?) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    static func build(from url: URL) -> FSNode {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let vals = try? url.resourceValues(forKeys: keys)
        let isDir = vals?.isDirectory ?? false
        let size: Int64 = isDir ? 0 : Int64(vals?.fileSize ?? 0)
        return FSNode(url: url, isDirectory: isDir, size: size, modified: vals?.contentModificationDate)
    }

    func expand(showHidden: Bool) {
        guard isDirectory else { return }
        if isLoaded { isExpanded = true; return }
        isExpanded = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            let items = (try? fm.contentsOfDirectory(
                at: self.url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: opts
            )) ?? []
            let sorted = items
                .map { FSNode.build(from: $0) }
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            DispatchQueue.main.async {
                self.children = sorted
                self.isLoaded = true
            }
        }
    }
}

// MARK: - FSTreeView

struct FSTreeView: View {
    @ObservedObject var state: FileBrowserState
    let scanner: AppScanner

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar bar
            HStack(spacing: 12) {
                // Breadcrumb
                if let url = state.currentURL {
                    ScrollView(.horizontal, showsIndicators: false) {
                        BreadcrumbView(url: url) { crumbURL in
                            state.navigate(to: crumbURL, title: crumbURL.lastPathComponent)
                        }
                    }
                }

                Spacer()

                Toggle(isOn: Binding(
                    get: { state.showHidden },
                    set: { _ in state.toggleHidden() }
                )) {
                    Label("Hidden", systemImage: "eye")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show hidden files")

                Picker("Sort", selection: $state.sortBy) {
                    ForEach(FSSortOption.allCases, id: \.self) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
                .onChange(of: state.sortBy) { _ in state.applySort() }

                Button { state.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Column headers
            HStack {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Size")
                    .frame(width: 90, alignment: .trailing)
                Text("Date Modified")
                    .frame(width: 140, alignment: .trailing)
                Spacer().frame(width: 68)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if state.isLoading {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else if state.nodes.isEmpty {
                Spacer()
                Label("Empty folder", systemImage: "folder")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.nodes) { node in
                            FSNodeRow(
                                node: node,
                                depth: 0,
                                showHidden: state.showHidden,
                                onNavigate: { url, title in state.navigate(to: url, title: title) },
                                onTrash: { url, completion in scanner.moveToTrash(url, completion: completion) },
                                onDeleted: { state.remove(node: node) }
                            )
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Breadcrumb

struct BreadcrumbView: View {
    let url: URL
    let onTap: (URL) -> Void

    var components: [(name: String, url: URL)] {
        var parts: [(String, URL)] = []
        var current = url
        while true {
            let name = current.path == "/" ? "Macintosh HD" : current.lastPathComponent
            parts.append((name, current))
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return parts.reversed()
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(components.enumerated()), id: \.offset) { i, crumb in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(crumb.name) { onTap(crumb.url) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(i == components.count - 1 ? .primary : .secondary)
            }
        }
    }
}

// MARK: - FSNodeRow

struct FSNodeRow: View {
    @ObservedObject var node: FSNode
    let depth: Int
    let showHidden: Bool
    let onNavigate: (URL, String) -> Void
    let onTrash: (URL, @escaping (Error?) -> Void) -> Void
    let onDeleted: () -> Void

    @State private var isHovered = false
    @State private var showConfirm = false
    @State private var trashError: String?

    var body: some View {
        VStack(spacing: 0) {
            rowContent
            if let err = trashError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, CGFloat(depth) * 20 + 44)
                    .padding(.bottom, 4)
            }
            if node.isExpanded {
                ForEach(node.children) { child in
                    FSNodeRow(
                        node: child,
                        depth: depth + 1,
                        showHidden: showHidden,
                        onNavigate: onNavigate,
                        onTrash: onTrash,
                        onDeleted: { node.children.removeAll { $0.id == child.id } }
                    )
                    Divider().padding(.leading, CGFloat(depth + 1) * 20 + 16).opacity(0.3)
                }
                if node.isExpanded && !node.isLoaded {
                    HStack {
                        Spacer().frame(width: CGFloat(depth + 1) * 20 + 32)
                        ProgressView().controlSize(.mini)
                        Text("Loading…").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .confirmationDialog(
            node.isDirectory ? "Move folder \"\(node.name)\" to Trash?" : "Move \"\(node.name)\" to Trash?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(node.isDirectory
                 ? "The folder and all its contents will be moved to Trash."
                 : "File size: \(formatBytes(node.size))")
        }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            // Indent
            Spacer().frame(width: CGFloat(depth) * 20 + 8)

            // Expand chevron
            if node.isDirectory {
                Button {
                    if node.isExpanded {
                        node.isExpanded = false
                    } else {
                        node.expand(showHidden: showHidden)
                    }
                } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 16)
            }

            Spacer().frame(width: 4)

            // Icon
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)

            Spacer().frame(width: 6)

            // Name — double-click navigates into folder
            Text(node.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if node.isDirectory {
                        onNavigate(node.url, node.name)
                    }
                }

            // Size
            Group {
                if node.isDirectory {
                    Text("—")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(formatBytes(node.size))
                        .foregroundStyle(node.size > 500_000_000 ? .orange : .secondary)
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .frame(width: 90, alignment: .trailing)

            // Date
            Text(node.modified.map { shortDate($0) } ?? "—")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)

            // Action buttons (show on hover)
            HStack(spacing: 4) {
                Button {
                    NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")

                if node.isDirectory {
                    Button {
                        onNavigate(node.url, node.name)
                    } label: {
                        Image(systemName: "folder.badge.arrow.right")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .help("Open in browser")
                }

                Button { showConfirm = true } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Move to Trash")
            }
            .frame(width: 68, alignment: .trailing)
            .opacity(isHovered ? 1 : 0)

            Spacer().frame(width: 8)
        }
        .padding(.vertical, 5)
        .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.12) : Color.clear)
        .onHover { isHovered = $0 }
    }

    private func trash() {
        trashError = nil
        onTrash(node.url) { error in
            if let error {
                trashError = error.localizedDescription
            } else {
                onDeleted()
            }
        }
    }

    private var iconName: String {
        if node.isDirectory { return "folder.fill" }
        switch node.ext {
        case "app":                                        return "app.fill"
        case "gguf", "ggml", "bin", "safetensors",
             "pt", "pth", "onnx":                         return "cpu.fill"
        case "json", "yaml", "yml", "toml", "plist":      return "doc.badge.gearshape"
        case "log":                                        return "doc.text"
        case "zip", "tar", "gz", "xz", "bz2", "7z":      return "archivebox.fill"
        case "dmg", "iso":                                 return "opticaldisc"
        case "mp4", "mov", "mkv", "avi", "m4v":           return "film"
        case "mp3", "aac", "flac", "wav", "m4a":          return "music.note"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "pdf":                                        return "doc.richtext"
        case "swift", "py", "js", "ts", "go", "rs",
             "c", "cpp", "h":                             return "chevron.left.forwardslash.chevron.right"
        case "sh", "zsh", "bash":                         return "terminal"
        default:                                           return "doc"
        }
    }

    private var iconColor: Color {
        if node.isDirectory { return .blue }
        switch node.ext {
        case "app":                             return .indigo
        case "gguf", "ggml", "safetensors",
             "bin", "pt", "pth", "onnx":       return .purple
        case "mp4", "mov", "mkv", "avi":        return .red
        case "mp3", "aac", "flac", "wav":       return .pink
        case "png", "jpg", "jpeg", "gif":       return .orange
        case "pdf":                             return .red
        case "zip", "tar", "gz":               return .brown
        case "swift", "py", "js", "ts":         return .teal
        default:                               return .secondary
        }
    }
}

// MARK: - Helpers

private func shortDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    return f.string(from: date)
}
