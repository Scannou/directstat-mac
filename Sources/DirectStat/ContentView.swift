import DirectStatCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .welcome: WelcomeView()
            case .scanning: ScanningView()
            case .results: ResultsView()
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .navigationTitle(model.phase == .results ? (model.result?.displayName ?? "DirectStat") : "DirectStat")
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("DirectStat").font(.largeTitle.bold())
                Text("See what's filling your disk, folder by folder.")
                    .foregroundStyle(.secondary)
            }
            if let v = model.volume {
                DiskBar(volume: v).frame(width: 420)
            }
            HStack(spacing: 12) {
                Button { model.scanDisk() } label: {
                    Label("Scan Whole Disk", systemImage: "internaldrive")
                }
                .buttonStyle(.borderedProminent)
                Button { model.scanHome() } label: {
                    Label("Scan Home Folder", systemImage: "house")
                }
                Button { model.chooseFolder() } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
            }
            .controlSize(.large)
            Text("To see every folder, give DirectStat Full Disk Access in System Settings › Privacy & Security.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DiskBar: View {
    let volume: VolumeInfo

    var body: some View {
        let used = Double(volume.used) / Double(max(volume.total, 1))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(used > 0.95 ? Color.red : used > 0.85 ? Color.orange : Color.accentColor)
                        .frame(width: geo.size.width * used)
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(volume.name): \(Fmt.bytes(volume.used)) used")
                Spacer()
                Text("\(Fmt.bytes(volume.available)) free of \(Fmt.bytes(volume.total))").bold()
            }
            .font(.callout)
            if volume.purgeable > 1_000_000_000 {
                Text("macOS can also free \(Fmt.bytes(volume.purgeable)) of purgeable space on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Scanning

struct ScanningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Scanning \(model.scanPath)").font(.title3)
            HStack(spacing: 32) {
                stat("Files", Fmt.count(model.progress.files))
                stat("Folders", Fmt.count(model.progress.dirs))
                stat("Size", Fmt.bytes(model.progress.bytes))
            }
            Text(model.progress.currentPath)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 640)
            Button("Cancel") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.monospacedDigit().bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 110)
    }
}

// MARK: - Results

struct ResultsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VSplitView {
            HSplitView {
                OutlineTree()
                    .frame(minWidth: 420, idealWidth: 680, maxWidth: .infinity)
                SidePanel()
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
            }
            .frame(minHeight: 180, idealHeight: 340)
            TreemapPane()
                .frame(minHeight: 160, idealHeight: 320)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .toolbar { toolbar }
        .overlay {
            if let msg = model.busyMessage {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(msg)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.selectParent() } label: { Label("Parent Folder", systemImage: "arrow.up") }
                .help("Select the parent folder (⌘↑)")
                .disabled(model.selection?.parentDir == nil)
            Button { model.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .help("Show only the selected folder in the treemap")
                .disabled(!model.canZoomIn)
            Button { model.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .help("Zoom the treemap out one level")
                .disabled(model.zoomRoot == nil)
            Button {
                if let s = model.selection { model.reveal(s) }
            } label: { Label("Reveal in Finder", systemImage: "folder") }
                .help("Reveal in Finder")
                .disabled(model.selection == nil)
            Button {
                if let s = model.selection { model.delete(s, permanently: false) }
            } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move to Trash (⌘⌫)")
                .disabled(!model.canDelete(model.selection))
            Menu {
                Button("Rescan") { model.rescan() }
                Divider()
                Button("Scan Whole Disk") { model.scanDisk() }
                Button("Scan Home Folder") { model.scanHome() }
                Button("Choose Folder…") { model.chooseFolder() }
            } label: {
                Label("New Scan", systemImage: "arrow.clockwise")
            } primaryAction: {
                model.rescan()
            }
            .help("Rescan (click) or start a new scan (hold)")
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            if let r = model.result {
                Text("\(Fmt.bytes(r.root.size)) · \(Fmt.count(r.root.fileCount)) files · \(Fmt.count(r.root.dirCount)) folders · scanned in \(String(format: "%.1f", r.duration)) s")
                if r.unreadableCount > 0 {
                    Button("\(Fmt.count(r.unreadableCount)) folders unreadable: grant Full Disk Access") {
                        model.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer()
            if let v = model.volume {
                Text("Free: \(Fmt.bytes(v.available)) of \(Fmt.bytes(v.total))")
                    .foregroundStyle(v.available < v.total / 20 ? Color.red : Color.primary)
                ProgressView(value: Double(v.used), total: Double(max(v.total, 1)))
                    .frame(width: 90)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Side panel

struct SidePanel: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Cleanup").tag(0)
                Text("Largest Files").tag(1)
                Text("File Types").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case 0: CleanupList()
            case 1: LargestFilesList()
            default: TypesList()
            }
        }
    }
}

struct CleanupList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if let note = notScannedNote {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Not in this scan").font(.headline)
                            Spacer()
                            Text(Fmt.bytes(note)).bold().monospacedDigit()
                        }
                        Text("Used on disk but not found in folders: Time Machine snapshots, other volumes, system files, or folders without access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
            Section("Suggestions") {
                if model.hogs.isEmpty {
                    Text("No known space hogs found.").foregroundStyle(.secondary)
                }
                ForEach(model.hogs) { hog in
                    HogRow(hog: hog)
                }
            }
        }
        .listStyle(.inset)
    }

    /// For whole-disk scans: used space the scan couldn't account for.
    private var notScannedNote: Int64? {
        guard let r = model.result, let v = model.volume,
              r.rootPath == "/System/Volumes/Data" else { return nil }
        let gap = v.used - r.root.size
        return gap > 2_000_000_000 ? gap : nil
    }
}

struct HogRow: View {
    @EnvironmentObject var model: AppModel
    let hog: Hog
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(hog.title).font(.headline)
                Spacer()
                Text(Fmt.bytes(hog.size)).bold().monospacedDigit()
            }
            HStack(spacing: 6) {
                SafetyBadge(safety: hog.safety)
                if hog.nodes.count > 1 {
                    Button(expanded ? "Hide \(hog.nodes.count) folders" : "\(hog.nodes.count) folders") {
                        expanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else if let n = hog.nodes.first {
                    Text(n.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Text(hog.detail).font(.caption).foregroundStyle(.secondary)
            if expanded {
                ForEach(Array(hog.nodes.prefix(100).enumerated()), id: \.offset) { _, n in
                    HStack {
                        Text(n.path).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text(Fmt.bytes(n.size)).monospacedDigit()
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(.dir(n)) }
                    .contextMenu { menu(for: .dir(n)) }
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if let n = hog.nodes.first { model.select(.dir(n)) } }
        .contextMenu {
            if hog.nodes.count == 1, let n = hog.nodes.first { menu(for: .dir(n)) }
        }
    }

    @ViewBuilder private func menu(for ref: ItemRef) -> some View {
        Button("Reveal in Finder") { model.reveal(ref) }
        Button("Copy Path") { model.copyPath(ref) }
        Divider()
        Button("Move to Trash…") { model.delete(ref, permanently: false) }
            .disabled(!model.canDelete(ref))
        Button("Delete Permanently…") { model.delete(ref, permanently: true) }
            .disabled(!model.canDelete(ref))
    }
}

struct SafetyBadge: View {
    let safety: HogSafety

    var body: some View {
        let (text, color): (String, Color) = safety == .safe
            ? ("Safe to delete", .green) : ("Review first", .orange)
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct LargestFilesList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(Array(model.largestFiles.enumerated()), id: \.offset) { _, ref in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(ref.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.bytes(ref.size)).bold().monospacedDigit()
                }
                Text(ref.parentDir?.path ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.select(ref) }
            .contextMenu {
                Button("Reveal in Finder") { model.reveal(ref) }
                Button("Copy Path") { model.copyPath(ref) }
                Divider()
                Button("Move to Trash…") { model.delete(ref, permanently: false) }
                Button("Delete Permanently…") { model.delete(ref, permanently: true) }
            }
        }
        .listStyle(.inset)
    }
}

struct TypesList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let r = model.result {
            let total = r.root.size
            List(r.typesBySize.prefix(500)) { t in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(nsColor: NSColor(r.color(forType: t.id))))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.displayName)
                        Text("\(Fmt.count(t.count)) files").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.bytes(t.size)).bold().monospacedDigit()
                        Text(Fmt.percent(t.size, of: total)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
