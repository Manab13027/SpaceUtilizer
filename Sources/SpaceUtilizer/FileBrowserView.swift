import SwiftUI
import AppKit

// MARK: - FileBrowserView

struct FileBrowserView: View {
    let rootURL: URL
    let scanner: AppScanner
    @State private var rootNodes: [FileBrowserNode] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if rootNodes.isEmpty {
                Label("Folder is empty", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(rootNodes) { node in
                        FileBrowserNodeRow(node: node, depth: 0, scanner: scanner) {
                            rootNodes.removeAll { $0.id == node.id }
                        }
                    }
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(
                at: rootURL,
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
                rootNodes = nodes
                isLoading = false
            }
        }
    }
}

// MARK: - FileBrowserNodeRow

struct FileBrowserNodeRow: View {
    @ObservedObject var node: FileBrowserNode
    let depth: Int
    let scanner: AppScanner
    let onDeleted: () -> Void

    @State private var isHovered = false
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            rowContent
            if node.isExpanded {
                ForEach(node.children) { child in
                    FileBrowserNodeRow(node: child, depth: depth + 1, scanner: scanner) {
                        node.children.removeAll { $0.id == child.id }
                    }
                }
                if !node.isLoaded {
                    HStack {
                        Spacer().frame(width: CGFloat(depth + 1) * 20 + 16)
                        ProgressView().controlSize(.mini)
                        Text("Loading…").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .confirmationDialog(
            "Move \"\(node.name)\" to Trash?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(node.isDirectory
                 ? "This folder and all its contents (\(formatBytes(node.size))) will be moved to Trash."
                 : "This file (\(formatBytes(node.size))) will be moved to Trash.")
        }
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            // Indentation
            Spacer().frame(width: CGFloat(depth) * 20)

            // Expand chevron
            if node.isDirectory {
                Button {
                    if node.isExpanded {
                        node.isExpanded = false
                    } else {
                        node.expand()
                    }
                } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 14)
            }

            // Icon
            Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(for: node.url))
                .foregroundStyle(node.isDirectory ? .blue : .secondary)
                .frame(width: 16)

            // Name
            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Size
            Text(formatBytes(node.size))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(node.size > 1_073_741_824 ? .orange : .secondary)

            // Show in Finder
            Button {
                NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "")
            } label: {
                Image(systemName: "folder.badge.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .opacity(isHovered ? 1 : 0)

            // Trash
            Button { showConfirm = true } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Move to Trash")
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.1) : Color.clear)
        .onHover { isHovered = $0 }
    }

    private func trash() {
        scanner.moveToTrash(node.url) { error in
            if error == nil { onDeleted() }
        }
    }

    private func fileIcon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "gguf", "ggml", "bin", "safetensors", "pt", "pth", "onnx": return "cpu.fill"
        case "json", "yaml", "yml", "toml", "plist":                     return "doc.badge.gearshape"
        case "log":                                                        return "doc.text"
        case "zip", "tar", "gz", "xz", "bz2":                            return "archivebox.fill"
        case "dmg", "iso":                                                 return "opticaldisc"
        case "mp4", "mov", "mkv", "avi":                                  return "film"
        case "mp3", "aac", "flac", "wav":                                 return "music.note"
        case "png", "jpg", "jpeg", "gif", "webp":                         return "photo"
        case "pdf":                                                        return "doc.richtext"
        default:                                                           return "doc"
        }
    }
}
