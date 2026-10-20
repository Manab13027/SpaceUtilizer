import SwiftUI
import AppKit

struct UninstallSheet<Target: UninstallTarget>: View {
    @ObservedObject var target: Target
    let initialMode: UninstallMode
    let context: UsageContext
    let scanner: AppScanner
    /// Called when the user presses Done, with the URLs that were moved to the Trash.
    let onFinished: (_ trashed: Set<URL>) -> Void
    let onCancel: () -> Void

    @State private var mode: UninstallMode = .everything
    @State private var selection: Set<UUID> = []
    @State private var didInit = false

    @State private var usage: [UUID: [UsageReason]] = [:]
    @State private var checkingUsage = true
    @State private var showInUseConfirm = false

    @State private var isRunning = false
    @State private var isWorking = false
    @State private var done = 0
    @State private var total = 0
    @State private var failures: [(url: URL, error: Error)] = []
    @State private var finished = false
    @State private var trashedURLs: Set<URL> = []

    private var items: [UninstallItem] { target.uninstallItems }
    private var selectedItems: [UninstallItem] { topLevelItems(items.filter { selection.contains($0.id) }) }
    private var selectedSize: Int64 { selectedItems.reduce(0) { $0 + max($1.size, 0) } }
    private var stillSizing: Bool { selectedItems.contains { $0.size < 0 } }
    private var selectedInUse: [UninstallItem] { items.filter { selection.contains($0.id) && usage[$0.id] != nil } }
    private var removesSource: Bool { items.contains { $0.group == .sourceCode && selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if finished {
                resultView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        modePicker
                        if isRunning { runningWarning }
                        if removesSource && !target.warnings.isEmpty { sourceWarnings }
                        usageBanner
                        ForEach(ItemGroup.allCases, id: \.self) { group in
                            let groupItems = items.filter { $0.group == group }
                            if !groupItems.isEmpty { section(group, groupItems) }
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 640)
        .onAppear(perform: start)
        .alert("Delete files other apps or projects use?", isPresented: $showInUseConfirm) {
            Button("Delete Anyway", role: .destructive) { run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inUseMessage)
        }
    }

    private var inUseMessage: String {
        let names = Set(selectedInUse.flatMap { usage[$0.id] ?? [] }.map(\.name)).sorted()
        let titles = selectedInUse.map(\.title).joined(separator: ", ")
        let verb = selectedInUse.count == 1 ? "is" : "are"
        return "\(titles) \(verb) used by \(names.joined(separator: ", ")). They may stop working."
    }

    // MARK: Setup

    private func start() {
        guard !didInit else { return }
        didInit = true
        mode = target.uninstallModes.contains(initialMode) ? initialMode : (target.uninstallModes.first ?? .everything)
        applyMode()
        refreshRunning()

        let ownAppPaths = items.filter { $0.group == .application }.map { $0.path.standardizedFileURL.path }
        let request = UsageChecker.Request(items: items, ownerName: target.displayName,
                                           keywords: target.referenceKeywords, container: target.containerFolder,
                                           ownBundleIDs: target.runningBundleIDs, ownAppPaths: ownAppPaths,
                                           context: context)
        UsageChecker.check(request) { result in
            usage = result
            checkingUsage = false
            // Anything another app or project relies on is unticked — tick it yourself to delete it anyway
            selection.subtract(result.keys)
        }
    }

    private func applyMode() {
        selection = target.defaultSelection(for: mode).subtracting(usage.keys)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 14) {
            if let icon = target.iconImage {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Remove \(target.displayName)").font(.title3.bold())
                Text("Everything goes to the Trash, so you can put it back until you empty it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $mode) {
                ForEach(target.uninstallModes) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isWorking)
            .onChange(of: mode) { _ in applyMode() }
            Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isWorking {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 160)
                Text("Moving \(min(done + 1, total)) of \(total)…").font(.caption).foregroundStyle(.secondary)
            } else if checkingUsage && !finished {
                ProgressView().controlSize(.small)
                Text("Checking whether other apps or projects use these files…").font(.caption).foregroundStyle(.secondary)
            } else if !finished {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedItems.count) items selected").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("Frees about \(formatBytes(selectedSize))").font(.headline)
                        if stillSizing { ProgressView().controlSize(.mini) }
                    }
                }
            }
            Spacer()
            if finished {
                Button("Done") { onFinished(trashedURLs) }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(role: .destructive) {
                    if selectedInUse.isEmpty { run() } else { showInUseConfirm = true }
                } label: {
                    Text("Move \(selectedItems.count) Items to Trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isWorking || checkingUsage || selectedItems.isEmpty || isRunning)
            }
        }
        .padding(16)
    }

    // MARK: Banners

    @ViewBuilder
    private var usageBanner: some View {
        if !checkingUsage && !usage.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(usageHeadline).font(.caption.bold())
                    Text("They were unticked so those apps and projects keep working. Tick them only if you're sure.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var usageHeadline: String {
        let names = Set(usage.values.flatMap { $0 }.map(\.name)).sorted()
        let n = usage.count
        return "\(n) item\(n == 1 ? " is" : "s are") still used by: \(names.joined(separator: ", "))"
    }

    private var sourceWarnings: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(target.warnings, id: \.self) { Text($0).font(.caption) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var runningWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(target.displayName) is running. Quit it first so it doesn't recreate its files.")
                .font(.caption)
            Spacer()
            Button("Quit It") {
                runningInstances().forEach { $0.terminate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refreshRunning() }
            }
            Button("Recheck") { refreshRunning() }.buttonStyle(.link)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Sections

    private func section(_ group: ItemGroup, _ groupItems: [UninstallItem]) -> some View {
        let allOn = groupItems.allSatisfy { selection.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.title).font(.headline)
                Spacer()
                Button(allOn ? "Deselect All" : "Select All") {
                    for it in groupItems {
                        if allOn { selection.remove(it.id) } else { selection.insert(it.id) }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(isWorking)
            }
            if let sub = group.subtitle {
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(groupItems.enumerated()), id: \.element.id) { idx, item in
                    row(item, color: group.color)
                    if idx < groupItems.count - 1 { Divider().padding(.leading, 40) }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ item: UninstallItem, color: Color) -> some View {
        let binding = Binding<Bool>(
            get: { selection.contains(item.id) },
            set: { on in if on { selection.insert(item.id) } else { selection.remove(item.id) } }
        )
        let reasons = usage[item.id] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle("", isOn: binding).toggleStyle(.checkbox).labelsHidden().disabled(isWorking)
                Image(systemName: item.icon).foregroundStyle(color).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !reasons.isEmpty {
                            Text("In use")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.18))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    Text(item.displayPath)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(item.paths.map(\.path).joined(separator: "\n"))
                    if item.group != .libraryFiles {
                        Text(item.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                Spacer()
                if item.size < 0 {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(formatBytes(item.size))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(item.size > 1_073_741_824 ? .orange : .secondary)
                }
                Button {
                    NSWorkspace.shared.selectFile(item.path.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder.badge.magnifyingglass").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
            ForEach(reasons) { r in
                Label(r.sentence, systemImage: r.icon)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.leading, 56)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    // MARK: Result

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if failures.isEmpty {
                Label("Moved \(total) item\(total == 1 ? "" : "s") to the Trash.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
                Text("Empty the Trash to actually free the space.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("\(total - failures.count) of \(total) items moved to the Trash.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Text("These couldn't be moved. If they are in ~/Library/Containers, give SpaceUtilizer Full Disk Access in System Settings › Privacy & Security and try again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(failures.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tildePath(failures[i].url.path)).font(.caption.monospaced())
                                Text(failures[i].error.localizedDescription).font(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func runningInstances() -> [NSRunningApplication] {
        target.runningBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    private func refreshRunning() {
        isRunning = runningInstances().contains { !$0.isTerminated }
    }

    private func run() {
        refreshRunning()
        guard !isRunning else { return }

        var urls = selectedItems.flatMap(\.paths)
        // Project fully selected → trash the project folder itself instead of its pieces
        if let container = target.containerFolder {
            let inside = items.filter { $0.paths.allSatisfy { isInside($0, container) } }
            if !inside.isEmpty && inside.allSatisfy({ selection.contains($0.id) }) {
                urls = urls.filter { !isInside($0, container) } + [container]
            }
        }
        // The app first (if it can't be removed you find out straight away), then the rest
        let appPaths = Set(items.filter { $0.group == .application }.map(\.path))
        urls.sort { appPaths.contains($0) && !appPaths.contains($1) }

        total = urls.count
        done = 0
        isWorking = true
        scanner.trashAll(urls, progress: { d, _ in done = d }) { fails in
            failures = fails
            isWorking = false
            finished = true
            trashedURLs = Set(urls).subtracting(fails.map { $0.url })
        }
    }
}
