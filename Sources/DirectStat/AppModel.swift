import AppKit
import DirectStatCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case welcome, scanning, results }

    @Published private(set) var phase: Phase = .welcome
    @Published private(set) var progress = ScanProgress()
    @Published private(set) var scanPath = ""
    @Published private(set) var result: ScanResult?
    @Published private(set) var hogs: [Hog] = []
    @Published private(set) var largestFiles: [ItemRef] = []
    @Published private(set) var volume: VolumeInfo?
    /// Bumped whenever the tree changes (an item was deleted).
    @Published private(set) var revision = 0
    /// The folder whose contents changed in the last deletion.
    private(set) var changedDir: DirNode?
    @Published private(set) var busyMessage: String?
    @Published var selection: ItemRef?
    /// Folder the treemap is zoomed into. Nil means the scan root.
    @Published var zoomRoot: DirNode?

    private var scanner: DiskScanner?
    private var timer: Timer?

    init() {
        volume = VolumeInfo.forPath("/")
        // `DirectStat --scan <path>` starts scanning right away.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.async { self.startScan(path) }
        }
    }

    var treemapRoot: DirNode? { zoomRoot ?? result?.root }

    // MARK: Scanning

    func scanDisk() { startScan("/") }
    func scanHome() { startScan(NSHomeDirectory()) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan"
        if panel.runModal() == .OK, let url = panel.url {
            startScan(url.path)
        }
    }

    func rescan() {
        if let r = result { startScan(r.rootPath) }
    }

    func startScan(_ path: String) {
        scanner?.cancel()
        let s = DiskScanner(path: path)
        scanner = s
        scanPath = s.rootPath
        progress = ScanProgress()
        phase = .scanning
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.scanner else { return }
                self.progress = s.progress
            }
        }
        Task.detached(priority: .userInitiated) {
            let r = s.run()
            let hogs = r.map { HogFinder.find(in: $0) } ?? []
            let files = r.map { Queries.largestFiles(in: $0.root, limit: 300) } ?? []
            await MainActor.run {
                self.finishScan(s, r, hogs, files)
            }
        }
    }

    private func finishScan(_ s: DiskScanner, _ r: ScanResult?, _ hogs: [Hog], _ files: [ItemRef]) {
        guard scanner === s else { return }
        scanner = nil
        timer?.invalidate()
        timer = nil
        guard let r else {
            phase = result == nil ? .welcome : .results
            return
        }
        selection = nil
        zoomRoot = nil
        result = r
        self.hogs = hogs
        largestFiles = files
        volume = VolumeInfo.forPath(r.rootPath)
        phase = .results
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        timer?.invalidate()
        timer = nil
        phase = result == nil ? .welcome : .results
    }

    // MARK: Navigation

    func select(_ ref: ItemRef?) { selection = ref }

    func selectParent() {
        guard let sel = selection, let p = sel.parentDir else { return }
        selection = .dir(p)
    }

    var canZoomIn: Bool { selection != nil && zoomTarget(selection!) !== treemapRoot }

    func zoomIn() {
        guard let sel = selection else { return }
        zoomRoot = zoomTarget(sel)
        if zoomRoot === result?.root { zoomRoot = nil }
    }

    func zoomOut() {
        guard let z = zoomRoot else { return }
        zoomRoot = (z.parent === result?.root) ? nil : z.parent
    }

    private func zoomTarget(_ ref: ItemRef) -> DirNode {
        switch ref {
        case .dir(let d): return d.isEmpty ? (d.parent ?? d) : d
        case .file(let d, _): return d
        }
    }

    // MARK: Actions

    func reveal(_ ref: ItemRef) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
    }

    func open(_ ref: ItemRef) {
        NSWorkspace.shared.open(URL(fileURLWithPath: ref.path))
    }

    func copyPath(_ ref: ItemRef) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Paths.withoutDataVolume(ref.path), forType: .string)
    }

    func openFullDiskAccessSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    func canDelete(_ ref: ItemRef?) -> Bool {
        guard let ref, let result, busyMessage == nil else { return false }
        return ref != .dir(result.root)
    }

    /// Asks for confirmation, then moves the item to the Trash or deletes it.
    func delete(_ ref: ItemRef, permanently: Bool) {
        guard canDelete(ref), let result else { return }
        let name = ref.name
        let size = Fmt.bytes(ref.size)
        let path = ref.path
        let inTrash = Paths.withoutDataVolume(path).hasPrefix(NSHomeDirectory() + "/.Trash/")
        let permanent = permanently || inTrash

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = permanent
            ? "Delete “\(name)” permanently?"
            : "Move “\(name)” to the Trash?"
        alert.informativeText = permanent
            ? "\(size) will be freed. This can't be undone.\n\n\(Paths.withoutDataVolume(path))"
            : "\(size). The space is freed when you empty the Trash.\n\n\(Paths.withoutDataVolume(path))"
        alert.addButton(withTitle: permanent ? "Delete" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if permanent { alert.buttons[0].hasDestructiveAction = true }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        busyMessage = permanent ? "Deleting \(name)…" : "Moving \(name) to the Trash…"
        Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            let failure: String?
            do {
                if permanent {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.busyMessage = nil
                if let failure {
                    let a = NSAlert()
                    a.messageText = "Couldn't delete “\(name)”"
                    a.informativeText = failure
                    a.runModal()
                    return
                }
                self.applyRemoval(ref, in: result)
            }
        }
    }

    private func applyRemoval(_ ref: ItemRef, in result: ScanResult) {
        guard result === self.result else { return }
        if case .dir(let d) = ref, let z = zoomRoot, z === d || d.isAncestor(of: z) {
            zoomRoot = nil
        }
        selection = nil
        changedDir = ref.parentDir
        // File rows in the changed folder shift index; drop them until the
        // list is rebuilt below so no row points at the wrong file.
        let changed = ref.parentDir
        let removedDir: DirNode? = { if case .dir(let d) = ref { return d }; return nil }()
        largestFiles.removeAll { r in
            let d = r.containingDir
            if d === changed { return true }
            if let removedDir, d === removedDir || removedDir.isAncestor(of: d) { return true }
            return false
        }
        result.remove(ref)
        revision += 1
        volume = VolumeInfo.forPath(result.rootPath)
        Task.detached(priority: .utility) {
            let hogs = HogFinder.find(in: result)
            let files = Queries.largestFiles(in: result.root, limit: 300)
            await MainActor.run {
                guard result === self.result else { return }
                self.hogs = hogs
                self.largestFiles = files
            }
        }
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number)
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "–" }
        return String(format: "%.1f%%", Double(part) / Double(whole) * 100)
    }
}
