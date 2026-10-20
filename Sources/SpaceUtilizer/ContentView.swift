import SwiftUI

enum SortOption: String, CaseIterable {
    case totalSize = "Total Size"
    case appSize   = "App Size"
    case name      = "Name"
    case lastUsed  = "Last Used"
}

enum SidebarMode: String, CaseIterable {
    case apps = "Applications"
    case projects = "Projects"
}

struct ContentView: View {
    @StateObject private var scanner = AppScanner()
    @StateObject private var projectScanner = ProjectScanner()
    @State private var sidebarMode: SidebarMode = .apps
    @State private var selectedApp: AppInfo?
    @State private var selectedProject: ProjectInfo?
    @State private var sortBy: SortOption = .totalSize
    @State private var searchText = ""
    @State private var diskInfo: DiskInfo? = DiskInfo.load()

    var displayedApps: [AppInfo] {
        var list = scanner.apps
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortBy {
        case .totalSize: list.sort { $0.totalSize > $1.totalSize }
        case .appSize:   list.sort { $0.appSize > $1.appSize }
        case .name:      list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsed:  list.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }
        return list
    }

    var displayedProjects: [ProjectInfo] {
        var list = projectScanner.projects
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortBy {
        case .totalSize: list.sort { $0.totalSize > $1.totalSize }
        case .appSize:   list.sort { $0.folderSize > $1.folderSize }
        case .name:      list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsed:  list.sort { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        }
        return list
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if let disk = diskInfo {
                    DiskSpaceBanner(disk: disk)
                    Divider()
                }
                Picker("", selection: $sidebarMode) {
                    ForEach(SidebarMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()

                if sidebarMode == .apps {
                    if !scanner.apps.isEmpty {
                        summaryHeader
                        Divider()
                    }
                    if scanner.isScanning {
                        scanProgress
                        Divider()
                    }
                    List(displayedApps, selection: $selectedApp) { app in
                        AppRowView(app: app).tag(app)
                    }
                    .listStyle(.sidebar)
                } else {
                    projectRootsHeader
                    Divider()
                    List(displayedProjects, selection: $selectedProject) { project in
                        ProjectRowView(project: project).tag(project)
                    }
                    .listStyle(.sidebar)
                }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
            .navigationTitle(sidebarMode.rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { scanner.scan(); projectScanner.scan() } label: {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                    .disabled(scanner.isScanning)
                    .keyboardShortcut("r", modifiers: .command)
                }
                ToolbarItem {
                    Picker("Sort", selection: $sortBy) {
                        ForEach(SortOption.allCases, id: \.self) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .help("Sort by")
                }
                ToolbarItem {
                    Button { openFileBrowserWindow(scanner: scanner) } label: {
                        Label("File Browser", systemImage: "folder.badge.magnifyingglass")
                    }
                    .help("Open File Browser")
                    .keyboardShortcut("b", modifiers: .command)
                }
            }
        } detail: {
            if sidebarMode == .apps, let app = selectedApp {
                AppDetailView(app: app, scanner: scanner, projectScanner: projectScanner) {
                    scanner.removeApp(app)
                    selectedApp = nil
                    diskInfo = DiskInfo.load()
                }
                .id(app.id)
                .onAppear { scanner.computeSizesIfNeeded(for: app) }
            } else if sidebarMode == .projects, let project = selectedProject {
                ProjectDetailView(project: project, projectScanner: projectScanner, appScanner: scanner) {
                    selectedProject = nil
                    diskInfo = DiskInfo.load()
                }
                .id(project.id)
                .onAppear { projectScanner.loadDetails(project, appScanner: scanner) }
            } else if sidebarMode == .projects {
                projectsPlaceholder
            } else {
                placeholderView
            }
        }
        .onAppear {
            scanner.scan()
            projectScanner.scan()
            diskInfo = DiskInfo.load()
        }
    }

    // MARK: - Subviews

    private var projectRootsHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Project Folders").font(.caption.bold())
                Spacer()
                if projectScanner.isScanning { ProgressView().controlSize(.mini) }
                Button { addProjectRoot() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add a folder that contains your projects")
            }
            if projectScanner.roots.isEmpty {
                Text("Add the folder where you keep your projects.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(projectScanner.roots, id: \.self) { root in
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(tildePath(root.path)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { projectScanner.removeRoot(root) } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop showing projects from this folder (nothing is deleted)")
                }
                .font(.caption)
            }
            Text("\(projectScanner.projects.count) projects")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func addProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the folder(s) where you keep your projects"
        if panel.runModal() == .OK {
            projectScanner.addRoots(panel.urls)
        }
    }

    private var projectsPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "hammer.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.indigo.opacity(0.7))
            if projectScanner.roots.isEmpty {
                Text("Add the folder where you keep your projects").font(.title3)
                Button("Add Folder…") { addProjectRoot() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Select a project to see what it uses and remove it")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var summaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(scanner.apps.count) apps")
                    .font(.caption.bold())
                Text("Total: \(formatBytes(scanner.apps.reduce(0) { $0 + $1.totalSize }))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: scanner.scanProgress)
            Text(scanner.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var placeholderView: some View {
        VStack(spacing: 24) {
            if let disk = diskInfo {
                DiskSpaceCard(disk: disk)
                    .frame(maxWidth: 460)
            }

            VStack(spacing: 16) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue.opacity(0.7))

                if scanner.isScanning {
                    Text("Scanning your Mac...")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    ProgressView(value: scanner.scanProgress)
                        .frame(maxWidth: 300)
                    Text(scanner.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if scanner.apps.isEmpty {
                    Text("SpaceUtilizer")
                        .font(.title.bold())
                    Text("Find all apps and their hidden files.\nSee what's using your storage.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Scan Now") { scanner.scan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Text("Select an app to view details")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Disk Space Banner (sidebar compact)

struct DiskSpaceBanner: View {
    let disk: DiskInfo

    var freeColor: Color {
        let pct = Double(disk.free) / Double(disk.total)
        if pct < 0.1 { return .red }
        if pct < 0.2 { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Label("Macintosh HD", systemImage: "internaldrive.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text(formatBytes(disk.free) + " free")
                    .font(.caption.bold())
                    .foregroundStyle(freeColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [.blue, disk.usedFraction > 0.85 ? .red : .blue.opacity(0.6)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(disk.usedFraction), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                Text(formatBytes(disk.used) + " used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(disk.total) + " total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Disk Space Card (detail panel)

struct DiskSpaceCard: View {
    let disk: DiskInfo

    var freePercent: Int { Int((Double(disk.free) / Double(disk.total)) * 100) }
    var usedPercent: Int { 100 - freePercent }

    var statusColor: Color {
        if freePercent < 10 { return .red }
        if freePercent < 20 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Macintosh HD", systemImage: "internaldrive.fill")
                    .font(.headline)
                Spacer()
                Text("\(freePercent)% free")
                    .font(.subheadline.bold())
                    .foregroundStyle(statusColor)
            }

            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            LinearGradient(
                                colors: [.blue, disk.usedFraction > 0.85 ? .red : .blue.opacity(0.7)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(disk.usedFraction), height: 12)
                }
            }
            .frame(height: 12)

            // Stats row
            HStack(spacing: 0) {
                DiskStatItem(label: "Total", value: formatBytes(disk.total), color: .blue)
                Spacer()
                DiskStatItem(label: "Used", value: formatBytes(disk.used), color: .blue.opacity(0.6))
                Spacer()
                DiskStatItem(label: "Free", value: formatBytes(disk.free), color: statusColor)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

struct DiskStatItem: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - App Row

struct AppRowView: View {
    @ObservedObject var app: AppInfo

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundStyle(.gray)
                        .padding(2)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(formatBytes(app.totalSize))
                        .font(.caption)
                        .foregroundStyle(sizeColor(app.totalSize))

                    if !app.associatedFiles.isEmpty {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("\(app.associatedFiles.count) files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func sizeColor(_ bytes: Int64) -> Color {
        let gb = Double(bytes) / 1_073_741_824
        if gb > 3 { return .red }
        if gb > 0.5 { return .orange }
        return .secondary
    }
}
