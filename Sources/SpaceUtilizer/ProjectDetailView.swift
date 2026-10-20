import SwiftUI
import AppKit

struct ProjectDetailView: View {
    @ObservedObject var project: ProjectInfo
    let projectScanner: ProjectScanner
    let appScanner: AppScanner
    let onDeleted: () -> Void

    @State private var uninstallMode: UninstallMode?

    private func freed(_ mode: UninstallMode) -> Int64 { project.size(of: project.defaultSelection(for: mode)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(24)
                if project.detailsLoaded && !project.git.warnings.isEmpty {
                    gitWarnings.padding(.horizontal, 24).padding(.bottom, 16)
                }
                Divider()
                if project.detailsLoaded {
                    storage.padding(24)
                    Divider()
                    contents.padding(24)
                    Divider()
                    removeSection.padding(24)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking inside \(project.name)…").foregroundStyle(.secondary)
                    }
                    .padding(24)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle(project.name)
        .sheet(item: $uninstallMode) { mode in
            UninstallSheet(
                target: project,
                initialMode: mode,
                context: UsageContext.make(apps: appScanner.apps, projects: projectScanner.projects,
                                           excludingApps: project.relatedAppIDs, excludingProject: project.url),
                scanner: appScanner,
                onFinished: { trashed in
                    uninstallMode = nil
                    if let app = project.linkedApp, trashed.contains(app.path) {
                        appScanner.removeApp(app)
                    }
                    if trashed.contains(project.url) {
                        projectScanner.removeProject(project)
                        onDeleted()
                    } else {
                        projectScanner.loadDetails(project, appScanner: appScanner, force: true)
                    }
                },
                onCancel: { uninstallMode = nil }
            )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: project.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text(project.name).font(.title2.bold())
                Text(tildePath(project.url.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    ForEach(project.kinds, id: \.self) { kind in
                        Text(kind)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.12))
                            .foregroundStyle(.indigo)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 12) {
                    if let d = project.lastModified {
                        Label("Changed \(relativeDate(d))", systemImage: "clock")
                    }
                    if project.git.isRepo && !project.git.branch.isEmpty {
                        Label(project.git.branch, systemImage: "arrow.triangle.branch")
                    }
                    if let app = project.linkedApp {
                        Label("Installed: \(app.installLocation)/\(app.name).app", systemImage: "checkmark.seal.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url])
                } label: {
                    Label("Show in Finder", systemImage: "folder").frame(minWidth: 140)
                }
                Button {
                    projectScanner.loadDetails(project, appScanner: appScanner, force: true)
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise").frame(minWidth: 140)
                }
            }
        }
    }

    private var gitWarnings: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(project.git.warnings, id: \.self) { Text($0).font(.caption) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Storage

    private var storage: some View {
        let items = project.uninstallItems
        let total = max(project.totalSize, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Storage").font(.headline)
                Spacer()
                Text(formatBytes(project.totalSize)).font(.title3.bold())
            }
            VStack(spacing: 6) {
                ForEach(ItemGroup.allCases, id: \.self) { g in
                    let size = topLevelItems(items.filter { $0.group == g }).reduce(0) { $0 + max($1.size, 0) }
                    if size > 0 {
                        StorageRow(label: g.title, size: size, color: g.color, total: total)
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Contents

    private var contents: some View {
        let items = project.uninstallItems
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(ItemGroup.allCases, id: \.self) { g in
                let groupItems = items.filter { $0.group == g }
                if !groupItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(g.title).font(.subheadline.bold())
                        VStack(spacing: 0) {
                            ForEach(Array(groupItems.enumerated()), id: \.element.id) { idx, item in
                                ProjectItemRow(item: item, color: g.color)
                                if idx < groupItems.count - 1 { Divider().padding(.leading, 40) }
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: Remove

    private var removeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove").font(.headline)
            VStack(spacing: 8) {
                DeleteCard(
                    title: "Clean Build Files",
                    subtitle: "Keep the project — node_modules, venvs, build output go",
                    sizeLabel: "~" + formatBytes(freed(.buildOnly)) + " freed",
                    color: .brown,
                    icon: "hammer"
                ) { uninstallMode = .buildOnly }

                DeleteCard(
                    title: "Delete, Keep Models & Data",
                    subtitle: "Code, build files" + (project.linkedApp != nil ? " and installed app" : "") + " go — models & data stay",
                    sizeLabel: "~" + formatBytes(freed(.keepData)) + " freed",
                    color: .purple,
                    icon: "cube.transparent"
                ) { uninstallMode = .keepData }

                DeleteCard(
                    title: "Delete Completely",
                    subtitle: "Project folder" + (project.linkedApp != nil ? ", installed app" : "") + ", models & data",
                    sizeLabel: "~" + formatBytes(freed(.everything)) + " freed",
                    color: .red,
                    icon: "trash.fill"
                ) { uninstallMode = .everything }
            }
            Text("You'll see every file before anything is deleted. Anything another app or project still uses is left unticked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Row

struct ProjectItemRow: View {
    let item: UninstallItem
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(item.displayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.paths.map(\.path).joined(separator: "\n"))
                Text(item.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if item.size < 0 {
                ProgressView().controlSize(.mini)
            } else {
                Text(formatBytes(item.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(item.size > 1_073_741_824 ? .orange : .secondary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(item.paths)
            } label: {
                Image(systemName: "folder.badge.magnifyingglass").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Sidebar row

struct ProjectRowView: View {
    @ObservedObject var project: ProjectInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: project.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(project.folderSize < 0 ? "Sizing…" : formatBytes(project.totalSize))
                        .font(.caption)
                        .foregroundStyle(project.totalSize > 3_221_225_472 ? .red : .secondary)
                    if !project.kinds.isEmpty {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(project.kinds.filter { $0 != "Git" }.prefix(2).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
