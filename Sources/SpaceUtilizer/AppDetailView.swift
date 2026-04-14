import SwiftUI
import AppKit

enum DetailTab: String, CaseIterable {
    case overview    = "Overview"
    case fileBrowser = "Browse Files"
}

struct AppDetailView: View {
    @ObservedObject var app: AppInfo
    let scanner: AppScanner
    let onDeleted: () -> Void

    @State private var showDeleteAppAlert = false
    @State private var showDeleteAllAlert = false
    @State private var errorText: String?
    @State private var isDeleting = false
    @State private var selectedTab: DetailTab = .overview

    var associatedTotal: Int64 { app.associatedFiles.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                selectedTab == tab
                                    ? Color(NSColor.controlBackgroundColor)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Divider()

            if selectedTab == .overview {
                overviewTab
            } else {
                fileBrowserTab
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle(app.name)
        .alert("Move \"\(app.name)\" to Trash?", isPresented: $showDeleteAppAlert) {
            Button("Move to Trash", role: .destructive) { doDeleteApp() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the .app bundle (\(formatBytes(app.appSize))) will be moved to Trash. Associated files will remain.")
        }
        .alert("Move \"\(app.name)\" + All Files to Trash?", isPresented: $showDeleteAllAlert) {
            Button("Move All to Trash", role: .destructive) { doDeleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app and all \(app.associatedFiles.count) associated files (\(formatBytes(app.totalSize)) total) will be moved to Trash.")
        }
    }

    // MARK: - Overview tab

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                appHeaderSection.padding(24)
                Divider()
                storageSection.padding(24)
                if !app.associatedFiles.isEmpty {
                    Divider()
                    associatedFilesSection.padding(24)
                } else {
                    Divider()
                    noFilesNote.padding(24)
                }
                if !app.dataFolders.isEmpty {
                    Divider()
                    dataFoldersSection.padding(24)
                }
                Divider()
                deleteSection.padding(24)
            }
        }
    }

    // MARK: - File browser tab

    private var fileBrowserTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Build the list of root locations to browse
                let locations = allBrowseLocations()
                if locations.isEmpty {
                    Label("No file locations found.", systemImage: "questionmark.folder")
                        .foregroundStyle(.secondary)
                        .padding(24)
                } else {
                    ForEach(locations, id: \.url) { loc in
                        BrowseLocationSection(
                            label: loc.label,
                            icon: loc.icon,
                            color: loc.color,
                            url: loc.url,
                            scanner: scanner
                        )
                    }
                }
            }
            .padding(16)
        }
    }

    private struct BrowseLocation {
        let label: String
        let icon: String
        let color: Color
        let url: URL
    }

    private func allBrowseLocations() -> [BrowseLocation] {
        var locs: [BrowseLocation] = []

        // 1. The .app bundle itself
        locs.append(BrowseLocation(label: "\(app.name).app (bundle)", icon: "app.fill", color: .blue, url: app.path))

        // 2. Associated Library files/folders (directories only — files are listed in Overview)
        for file in app.associatedFiles {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            locs.append(BrowseLocation(
                label: file.category.rawValue + " — " + file.name,
                icon: file.category.systemImage,
                color: file.category.color,
                url: file.path
            ))
        }

        // 3. Known data folders (Ollama models, Xcode DerivedData, etc.)
        for folder in app.dataFolders {
            locs.append(BrowseLocation(
                label: folder.label,
                icon: "externaldrive.fill",
                color: .purple,
                url: folder.path
            ))
        }

        return locs
    }

    // MARK: - App Header

    private var appHeaderSection: some View {
        HStack(alignment: .top, spacing: 16) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 80, height: 80)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(app.name)
                    .font(.title2.bold())

                if let version = app.version {
                    Text("Version \(version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let bundleID = app.bundleID {
                    Text(bundleID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    Label(app.installLocation, systemImage: "folder")
                    if let lastUsed = app.lastUsed {
                        Label("Used \(relativeDate(lastUsed))", systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }

            Spacer()

            VStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.selectFile(app.path.path, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .frame(minWidth: 150)
                }

                Button {
                    NSWorkspace.shared.open(app.path)
                } label: {
                    Label("Open App", systemImage: "play.fill")
                        .frame(minWidth: 150)
                }
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Storage")
                    .font(.headline)
                Spacer()
                Text(formatBytes(app.totalSize))
                    .font(.title3.bold())
            }

            VStack(spacing: 6) {
                StorageRow(label: "Application (.app)", size: app.appSize, color: .blue, total: app.totalSize)
                ForEach(FileCategory.allCases, id: \.self) { cat in
                    let catSize = app.associatedFiles.filter { $0.category == cat }.reduce(0) { $0 + $1.size }
                    if catSize > 0 {
                        StorageRow(label: cat.rawValue, size: catSize, color: cat.color, total: app.totalSize)
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Associated Files

    private var associatedFilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Associated Files")
                    .font(.headline)
                Spacer()
                Text("\(app.associatedFiles.count) items · \(formatBytes(associatedTotal))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Files created by \(app.name) in system Library folders. Deleting the app does NOT remove these automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(app.associatedFiles.enumerated()), id: \.element.id) { index, file in
                    AssociatedFileRow(file: file) {
                        trashFile(file)
                    }
                    if index < app.associatedFiles.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var noFilesNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("No associated files found in Library directories.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.green.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Data Folders

    private var dataFoldersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Data & Downloads", systemImage: "externaldrive.fill")
                    .font(.headline)
                Spacer()
                Text(formatBytes(app.dataFolders.reduce(0) { $0 + $1.size }))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Files stored outside the app bundle — models, caches, databases, and other large data this app manages separately.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(app.dataFolders) { folder in
                DataFolderRow(folder: folder, scanner: scanner)
            }
        }
    }

    // MARK: - Delete

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove")
                .font(.headline)

            if isDeleting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Moving to Trash…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            HStack(spacing: 12) {
                DeleteCard(
                    title: "App Only",
                    subtitle: "Keeps preferences & data",
                    sizeLabel: formatBytes(app.appSize) + " freed",
                    color: .orange,
                    icon: "trash",
                    disabled: isDeleting
                ) { showDeleteAppAlert = true }

                DeleteCard(
                    title: "App + All Files",
                    subtitle: "Complete removal",
                    sizeLabel: formatBytes(app.totalSize) + " freed",
                    color: .red,
                    icon: "trash.fill",
                    disabled: isDeleting
                ) { showDeleteAllAlert = true }
            }

            if let err = errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Actions

    private func trashFile(_ file: AssociatedFile) {
        scanner.moveToTrash(file.path) { error in
            if let error {
                errorText = error.localizedDescription
            } else {
                scanner.removeAssociatedFile(file, from: app)
            }
        }
    }

    private func doDeleteApp() {
        isDeleting = true
        scanner.moveToTrash(app.path) { error in
            isDeleting = false
            if let error {
                errorText = error.localizedDescription
            } else {
                onDeleted()
            }
        }
    }

    private func doDeleteAll() {
        isDeleting = true
        scanner.deleteAppCompletely(app) { error in
            isDeleting = false
            if let error {
                errorText = error.localizedDescription
            } else {
                onDeleted()
            }
        }
    }
}

// MARK: - StorageRow

struct StorageRow: View {
    let label: String
    let size: Int64
    let color: Color
    let total: Int64

    var fraction: CGFloat { total > 0 ? CGFloat(size) / CGFloat(total) : 0 }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .frame(minWidth: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(geo.size.width * fraction, 2), height: 6)
                }
            }
            .frame(height: 6)
            Text(formatBytes(size))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
    }
}

// MARK: - AssociatedFileRow

struct AssociatedFileRow: View {
    let file: AssociatedFile
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.category.systemImage)
                .foregroundStyle(file.category.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if file.category.isSafeToDelete {
                        Text("Safe to delete")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                Text(file.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(file.path.path)
                Text(file.category.explanation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(formatBytes(file.size))
                .font(.caption.monospacedDigit())
                .foregroundStyle(file.size > 50_000_000 ? .orange : .secondary)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Move to Trash")
            .opacity(isHovered ? 1 : 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.08) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - BrowseLocationSection

struct BrowseLocationSection: View {
    let label: String
    let icon: String
    let color: Color
    let url: URL
    let scanner: AppScanner

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .frame(width: 18)

                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Button {
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "folder.badge.magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")

                    Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                FileBrowserView(rootURL: url, scanner: scanner)
                    .padding(.leading, 44)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

// MARK: - DataFolderRow

struct DataFolderRow: View {
    let folder: DataFolder
    let scanner: AppScanner
    @State private var isExpanded = false
    @State private var showTrashConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.purple)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(folder.label)
                            .font(.system(size: 13, weight: .semibold))
                        if folder.size > 1_073_741_824 {
                            Text("Large")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    Text(folder.displayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(folder.path.path)
                    Text(folder.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(formatBytes(folder.size))
                    .font(.system(size: 12).monospacedDigit().bold())
                    .foregroundStyle(folder.size > 1_073_741_824 ? .orange : .primary)

                Button {
                    NSWorkspace.shared.selectFile(folder.path.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder.badge.magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")

                Button { showTrashConfirm = true } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Move entire folder to Trash")
            }
            .padding(12)

            // Inline file browser
            if isExpanded {
                Divider().padding(.leading, 44)
                FileBrowserView(rootURL: folder.path, scanner: scanner)
                    .padding(.leading, 44)
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
        .confirmationDialog(
            "Move \"\(folder.label)\" folder to Trash?",
            isPresented: $showTrashConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                scanner.moveToTrash(folder.path) { _ in }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The entire \(folder.label) folder (\(formatBytes(folder.size))) will be moved to Trash.")
        }
    }
}

// MARK: - DeleteCard

struct DeleteCard: View {
    let title: String
    let subtitle: String
    let sizeLabel: String
    let color: Color
    let icon: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.bold())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    Text(sizeLabel).font(.caption.bold()).foregroundStyle(color)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(color.opacity(disabled ? 0.03 : 0.07))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(disabled ? 0.5 : 1)
        .allowsHitTesting(!disabled)
    }
}
