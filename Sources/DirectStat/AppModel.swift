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
    /// Folders whose contents changed in the last deletion.
    private(set) var changedDirs: [DirNode] = []
    @Published private(set) var busyMessage: String?
    /// The main selected item: the one the treemap, zoom and Open act on.
    /// Setting it to an item outside `selectedItems` selects only that item.
    @Published var selection: ItemRef? {
        didSet {
            if let s = selection {
                if !selectedItems.contains(s) { selectedItems = [s] }
            } else if !selectedItems.isEmpty {
                selectedItems = []
            }
        }
    }
    /// Every selected row of the folder tree. Contains `selection` when it is set.
    @Published private(set) var selectedItems: [ItemRef] = []
    /// Folder the treemap is zoomed into. Nil means the scan root.
    @Published var zoomRoot: DirNode?

    private var scanner: DiskScanner?
    private var timer: Timer?
    private var keyMonitor: Any?

    init() {
        volume = VolumeInfo.forPath("/")
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = event.keyCode, flags = event.modifierFlags
            let handled = MainActor.assumeIsolated { self?.handleDeleteKey(key, flags) ?? false }
            return handled ? nil : event
        }
        #if DEBUG
        // Dev aid: `DirectStat --scan <path>` starts scanning right away.
        // Debug builds only: the installed app has Full Disk Access, and any
        // local process could launch it with arguments.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.async { self.startScan(path) }
        }
        #endif
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

    /// Called by the folder tree with all its selected rows.
    func setSelection(_ items: [ItemRef], primary: ItemRef?) {
        selectedItems = items
        selection = primary ?? items.last
    }

    /// The Delete key (or forward delete) moves the selection to the Trash.
    /// With modifiers it is left to the menu shortcuts (⌘⌫, ⌥⌘⌫).
    private func handleDeleteKey(_ key: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        let deleteKeys: Set<UInt16> = [51, 117]  // delete, forward delete
        // Only in the main window, not in an alert, panel or sheet.
        guard deleteKeys.contains(key),
              flags.intersection([.command, .option, .control, .shift]).isEmpty,
              phase == .results, NSApp.modalWindow == nil,
              let window = NSApp.keyWindow, window === NSApp.mainWindow, window.attachedSheet == nil,
              !(window.firstResponder is NSText),
              canDelete(selectedItems) else { return false }
        delete(selectedItems, permanently: false)
        return true
    }

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

    func reveal(_ ref: ItemRef) { reveal([ref]) }

    func reveal(_ refs: [ItemRef]) {
        let urls = refs.filter(\.hasExactPath).map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func open(_ ref: ItemRef) {
        guard ref.hasExactPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: ref.path))
    }

    func copyPath(_ ref: ItemRef) { copyPaths([ref]) }

    /// One path per line.
    func copyPaths(_ refs: [ItemRef]) {
        let paths = refs.filter(\.hasExactPath).map { Paths.withoutDataVolume($0.path) }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func openFullDiskAccessSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    func canDelete(_ ref: ItemRef?) -> Bool {
        guard let ref, let result, busyMessage == nil else { return false }
        return ref != .dir(result.root) && ref.hasExactPath
    }

    func canDelete(_ refs: [ItemRef]) -> Bool {
        !refs.isEmpty && refs.allSatisfy { canDelete($0) }
    }

    /// Menu title for deleting `refs`, e.g. "Move 3 Items to Trash…".
    func deleteTitle(_ refs: [ItemRef], permanently: Bool) -> String {
        let n = ItemRef.outermost(refs).count
        if n <= 1 { return permanently ? "Delete Permanently…" : "Move to Trash…" }
        return permanently ? "Delete \(n) Items Permanently…" : "Move \(n) Items to Trash…"
    }

    func delete(_ ref: ItemRef, permanently: Bool) { delete([ref], permanently: permanently) }

    /// Asks for confirmation, then moves the items to the Trash or deletes them.
    /// Items inside another selected folder go with that folder.
    func delete(_ refs: [ItemRef], permanently: Bool) {
        let items = ItemRef.outermost(refs)
        guard canDelete(items), let result else { return }
        let trash = NSHomeDirectory() + "/.Trash/"
        // Items already in the Trash can only be deleted for good.
        let permanent = permanently || items.contains { Paths.withoutDataVolume($0.path).hasPrefix(trash) }
        let size = Fmt.bytes(items.reduce(0) { $0 + $1.size })
        let freed = permanent
            ? "\(size) will be freed. This can't be undone."
            : "\(size). The space is freed when you empty the Trash."

        let alert = NSAlert()
        alert.alertStyle = .warning
        if items.count == 1, let only = items.first {
            alert.messageText = permanent
                ? "Delete “\(only.name)” permanently?"
                : "Move “\(only.name)” to the Trash?"
            alert.informativeText = "\(freed)\n\n\(Paths.withoutDataVolume(only.path))"
        } else {
            alert.messageText = permanent
                ? "Delete \(items.count) items permanently?"
                : "Move \(items.count) items to the Trash?"
            let shown = 8
            var list = items.prefix(shown).map { Paths.withoutDataVolume($0.path) }
            if items.count > shown { list.append("…and \(items.count - shown) more") }
            alert.informativeText = "\(freed)\n\n" + list.joined(separator: "\n")
        }
        alert.addButton(withTitle: permanent ? "Delete" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if permanent { alert.buttons[0].hasDestructiveAction = true }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let what = items.count == 1 ? items[0].name : "\(items.count) items"
        busyMessage = permanent ? "Deleting \(what)…" : "Moving \(what) to the Trash…"
        let jobs = items.map { DeleteJob(ref: $0, name: $0.name, path: $0.path, isDirectory: $0.isDirectory) }
        Task.detached(priority: .userInitiated) {
            var deleted: [ItemRef] = []
            var failures: [(name: String, reason: String)] = []
            for job in jobs {
                do {
                    if let problem = DeleteCheck.problem(path: job.path, isDirectory: job.isDirectory) {
                        failures.append((job.name, problem))
                        continue
                    }
                    let url = URL(fileURLWithPath: job.path)
                    if permanent {
                        try FileManager.default.removeItem(at: url)
                    } else {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                    deleted.append(job.ref)
                } catch {
                    failures.append((job.name, error.localizedDescription))
                }
            }
            let done = deleted, failed = failures
            await MainActor.run {
                self.busyMessage = nil
                self.applyRemoval(done, in: result)
                guard !failed.isEmpty else { return }
                let a = NSAlert()
                if failed.count == 1, let f = failed.first {
                    a.messageText = "Couldn't delete “\(f.name)”"
                    a.informativeText = f.reason
                } else {
                    a.messageText = "Couldn't delete \(failed.count) items"
                    a.informativeText = failed.prefix(8).map { "\($0.name): \($0.reason)" }.joined(separator: "\n\n")
                }
                a.runModal()
            }
        }
    }

    private func applyRemoval(_ refs: [ItemRef], in result: ScanResult) {
        guard result === self.result, !refs.isEmpty else { return }
        let removedDirs = refs.compactMap { ref -> DirNode? in
            if case .dir(let d) = ref { return d }
            return nil
        }
        func underRemovedDir(_ d: DirNode) -> Bool {
            removedDirs.contains { $0 === d || $0.isAncestor(of: d) }
        }
        if let z = zoomRoot, underRemovedDir(z) { zoomRoot = nil }
        selection = nil
        changedDirs = refs.compactMap(\.parentDir)
        // File rows in a changed folder shift index; drop them until the
        // list is rebuilt below so no row points at the wrong file.
        let changed = Set(changedDirs.map(ObjectIdentifier.init))
        largestFiles.removeAll { r in
            let d = r.containingDir
            return changed.contains(ObjectIdentifier(d)) || underRemovedDir(d)
        }
        for d in removedDirs {
            hogs = hogs.compactMap { $0.removing(under: d) }
        }
        result.remove(refs)
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

private struct DeleteJob: Sendable {
    let ref: ItemRef
    let name: String
    let path: String
    let isDirectory: Bool
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    /// "Today at 14:05", "12 Mar 2024 at 09:30"; empty if unknown.
    static func date(_ d: Date?) -> String {
        d.map { dateFormatter.string(from: $0) } ?? ""
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "–" }
        return String(format: "%.1f%%", Double(part) / Double(whole) * 100)
    }
}
