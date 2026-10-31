import AppKit
import DirectStatCore
import SwiftUI

/// Row object for NSOutlineView. Folder rows are reused across reloads so the
/// outline keeps them expanded; file rows are rebuilt with their folder.
final class OutlineItem {
    let ref: ItemRef
    var cachedChildren: [OutlineItem]?
    init(_ ref: ItemRef) { self.ref = ref }

    var isExpandable: Bool {
        if case .dir(let d) = ref { return !d.isEmpty }
        return false
    }
}

struct OutlineTree: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let ov = NSOutlineView()
        ov.headerView = NSTableHeaderView()
        ov.usesAlternatingRowBackgroundColors = true
        ov.style = .fullWidth
        ov.rowHeight = 20
        ov.allowsMultipleSelection = true
        ov.autoresizesOutlineColumn = false
        ov.indentationPerLevel = 14
        // Extra width is shared by Name and the % bar; the other columns stay put.
        ov.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        /// `sort` is what clicking the header sorts by; the first click
        /// sorts ascending for names and largest/newest first otherwise.
        func column(_ id: String, _ title: String, _ width: CGFloat, min: CGFloat,
                    right: Bool = false, grows: Bool = true, sort: SortKey?) -> NSTableColumn {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = min
            c.resizingMask = grows ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if right { c.headerCell.alignment = .right }
            if let sort {
                c.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: sort == .name)
            }
            return c
        }
        let name = column("name", "Name", 260, min: 160, sort: .name)
        ov.addTableColumn(name)
        ov.outlineTableColumn = name
        // Sorting by share of parent is sorting by size, which the Size column does.
        ov.addTableColumn(column("bar", "% of Parent", 300, min: 80, sort: nil))
        ov.addTableColumn(column("size", "Size", 95, min: 70, right: true, grows: false, sort: .size))
        ov.addTableColumn(column("items", "Items", 85, min: 60, right: true, grows: false, sort: .items))
        let modified = column("modified", "Modified", 170, min: 90, grows: false, sort: .modified)
        modified.headerToolTip = "When the item last changed. Folders show the newest change anywhere inside."
        ov.addTableColumn(modified)
        ov.sortDescriptors = [NSSortDescriptor(key: SortKey.size.rawValue, ascending: false)]
        // Remember column widths and the sort order between launches. The name
        // changed when the Modified column was added: widths saved for the old
        // columns filled the view and pushed the new one out of sight.
        ov.autosaveName = "DirectStat.FolderTree.2"
        ov.autosaveTableColumns = true
        context.coordinator.readSort(ov.sortDescriptors)

        ov.dataSource = context.coordinator
        ov.delegate = context.coordinator
        ov.target = context.coordinator
        ov.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        ov.menu = menu
        context.coordinator.outline = ov

        let scroll = NSScrollView()
        scroll.documentView = ov
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(model: model)
    }

    // MARK: -

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var model: AppModel
        weak var outline: NSOutlineView?
        private var result: ScanResult?
        private var revision = -1
        private var rootItem: OutlineItem?
        private var dirItems: [ObjectIdentifier: OutlineItem] = [:]
        private var syncing = false
        private var sortKey = SortKey.size
        private var ascending = false

        init(model: AppModel) { self.model = model }

        func update(model: AppModel) {
            self.model = model
            guard let ov = outline else { return }
            syncing = true
            defer { syncing = false }
            if model.result !== result {
                result = model.result
                revision = model.revision
                dirItems = [:]
                rootItem = result.map { item(for: $0.root) }
                ov.reloadData()
                if let rootItem { ov.expandItem(rootItem) }
            } else if model.revision != revision {
                revision = model.revision
                for changed in model.changedDirs {
                    for d in changed.ancestors { dirItems[ObjectIdentifier(d)]?.cachedChildren = nil }
                }
                ov.reloadData()
            }
            syncSelection(model.selectedItems, primary: model.selection)
        }

        // MARK: Sorting

        func readSort(_ descriptors: [NSSortDescriptor]) {
            guard let d = descriptors.first, let key = d.key.flatMap(SortKey.init(rawValue:)) else { return }
            sortKey = key
            ascending = d.ascending
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            readSort(outlineView.sortDescriptors)
            for it in dirItems.values { it.cachedChildren = nil }
            syncing = true
            defer { syncing = false }
            // Rows move, so put the selection back on the same items.
            let selected = model.selectedItems
            outlineView.reloadData()
            outlineView.deselectAll(nil)
            syncSelection(selected, primary: model.selection)
        }

        private func item(for d: DirNode) -> OutlineItem {
            let key = ObjectIdentifier(d)
            if let it = dirItems[key] { return it }
            let it = OutlineItem(.dir(d))
            dirItems[key] = it
            return it
        }

        private func children(of it: OutlineItem) -> [OutlineItem] {
            if let c = it.cachedChildren { return c }
            guard case .dir(let d) = it.ref else { return [] }
            let c = d.children(sortedBy: sortKey, ascending: ascending).map { ref -> OutlineItem in
                if case .dir(let sub) = ref { return item(for: sub) }
                return OutlineItem(ref)
            }
            it.cachedChildren = c
            return c
        }

        // MARK: Selection sync

        private func selectedRefs(_ ov: NSOutlineView) -> [ItemRef] {
            ov.selectedRowIndexes.compactMap { (ov.item(atRow: $0) as? OutlineItem)?.ref }
        }

        private func syncSelection(_ refs: [ItemRef], primary: ItemRef?) {
            guard let ov = outline else { return }
            guard Set(selectedRefs(ov)) != Set(refs) else { return }
            // Expand everything first: expanding shifts the rows below.
            let targets = refs.map { ($0, reveal($0)) }
            let rows = IndexSet(targets.compactMap { $0.1.map(ov.row(forItem:)) }.filter { $0 >= 0 })
            guard !rows.isEmpty else {
                ov.deselectAll(nil)
                return
            }
            ov.selectRowIndexes(rows, byExtendingSelection: false)
            let main = targets.first { $0.0 == primary }?.1.map(ov.row(forItem:)) ?? rows.last!
            if main >= 0 { ov.scrollRowToVisible(main) }
        }

        /// Expands the outline down to `ref` and returns its row object.
        private func reveal(_ ref: ItemRef) -> OutlineItem? {
            guard let ov = outline, let rootItem, let result else { return nil }
            let chain = ref.containingDir.ancestors
            guard chain.first === result.root else { return nil }
            var cur = rootItem
            for d in chain.dropFirst() {
                ov.expandItem(cur)
                cur = item(for: d)
            }
            if case .file = ref {
                ov.expandItem(cur)
                return children(of: cur).first { $0.ref == ref }
            }
            return cur
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let ov = outline else { return }
            let refs = selectedRefs(ov)
            // selectedRow is the row clicked or added last.
            let row = ov.selectedRow
            let primary = row >= 0 ? (ov.item(atRow: row) as? OutlineItem)?.ref : nil
            if model.selectedItems != refs || model.selection != primary {
                model.setSelection(refs, primary: primary)
            }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let ov = outline, ov.clickedRow >= 0,
                  let it = ov.item(atRow: ov.clickedRow) as? OutlineItem else { return }
            if it.isExpandable {
                ov.isItemExpanded(it) ? ov.collapseItem(it) : ov.expandItem(it)
            } else {
                model.reveal(it.ref)
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let it = item as? OutlineItem else { return rootItem == nil ? 0 : 1 }
            return children(of: it).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let it = item as? OutlineItem else { return rootItem! }
            return children(of: it)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? OutlineItem)?.isExpandable ?? false
        }

        // MARK: Cells

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let it = item as? OutlineItem, let col = tableColumn, let result else { return nil }
            let ref = it.ref
            switch col.identifier.rawValue {
            case "name":
                let cell = reuse(outlineView, "name") { NameCell() }
                let isRoot = ref == .dir(result.root)
                cell.configure(ref: ref, title: isRoot ? result.displayName : ref.name, result: result)
                return cell
            case "bar":
                let cell = reuse(outlineView, "bar") { BarCell() }
                let parentSize = ref.parentDir?.size ?? ref.size
                cell.fraction = parentSize > 0 ? Double(ref.size) / Double(parentSize) : 1
                if case .file(let d, let i) = ref, i < d.files.count {
                    cell.color = NSColor(result.color(forType: d.files[i].typeID))
                } else {
                    cell.color = .systemBlue
                }
                return cell
            case "size":
                let cell = reuse(outlineView, "size") { TextCell(alignment: .right) }
                cell.textField?.stringValue = Fmt.bytes(ref.size)
                return cell
            case "modified":
                let cell = reuse(outlineView, "modified") { TextCell(alignment: .left) }
                cell.textField?.stringValue = Fmt.date(ref.modified)
                return cell
            case "items":
                let cell = reuse(outlineView, "items") { TextCell(alignment: .right) }
                if case .dir(let d) = ref {
                    cell.textField?.stringValue = Fmt.count(d.itemCount)
                } else {
                    cell.textField?.stringValue = ""
                }
                return cell
            default:
                return nil
            }
        }

        private func reuse<T: NSView>(_ ov: NSOutlineView, _ id: String, make: () -> T) -> T {
            if let v = ov.makeView(withIdentifier: .init(id), owner: nil) as? T { return v }
            let v = make()
            v.identifier = .init(id)
            return v
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let ov = outline, ov.clickedRow >= 0,
                  let it = ov.item(atRow: ov.clickedRow) as? OutlineItem else { return }
            let ref = it.ref
            // Right-clicking a selected row acts on the whole selection,
            // any other row on just that row.
            if !model.selectedItems.contains(ref) { model.selection = ref }
            let targets = model.selectedItems
            func add(_ title: String, _ action: @escaping () -> Void) {
                let mi = NSMenuItem(title: title, action: #selector(runMenu(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = MenuAction(action)
                menu.addItem(mi)
            }
            add("Reveal in Finder") { [model] in model.reveal(targets) }
            if targets.count <= 1 { add("Open") { [model] in model.open(ref) } }
            add(targets.count > 1 ? "Copy Paths" : "Copy Path") { [model] in model.copyPaths(targets) }
            if ref.isDirectory && targets.count <= 1 {
                menu.addItem(.separator())
                add("Zoom Treemap Here") { [model] in model.selection = ref; model.zoomIn() }
            }
            if model.canDelete(targets) {
                menu.addItem(.separator())
                add(model.deleteTitle(targets, permanently: false)) { [model] in
                    model.delete(targets, permanently: false)
                }
                add(model.deleteTitle(targets, permanently: true)) { [model] in
                    model.delete(targets, permanently: true)
                }
            }
        }

        @objc private func runMenu(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuAction)?.run()
        }
    }
}

private final class MenuAction {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

// MARK: - Cells

extension NSColor {
    convenience init(_ c: RGB) {
        self.init(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}

private final class NameCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(ref: ItemRef, title: String, result: ScanResult) {
        label.stringValue = title
        switch ref {
        case .dir(let d):
            if d.unreadable {
                icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "No access")
                icon.contentTintColor = .systemOrange
                label.textColor = .secondaryLabelColor
                toolTip = "Couldn't read this folder. Grant Full Disk Access to see inside."
            } else if d.otherVolume {
                icon.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Other volume")
                icon.contentTintColor = .secondaryLabelColor
                label.textColor = .secondaryLabelColor
                toolTip = "Another volume is mounted here. It was not scanned."
            } else {
                icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
                icon.contentTintColor = .systemBlue
                label.textColor = .labelColor
                toolTip = nil
            }
        case .file(let d, let i):
            let color = i < d.files.count ? result.color(forType: d.files[i].typeID) : Palette.other
            icon.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: "File")
            icon.contentTintColor = NSColor(color)
            label.textColor = .labelColor
            toolTip = nil
        }
    }
}

private final class TextCell: NSTableCellView {
    init(alignment: NSTextAlignment) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.alignment = alignment
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Bar showing the item's share of its parent folder, with the percentage.
private final class BarCell: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 3, dy: 4)
        let track = NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        var fill = inset
        fill.size.width = max(0, min(1, fraction)) * inset.width
        if fill.width > 0.5 {
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
        let text = String(format: "%.1f%%", fraction * 100) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: inset.maxX - size.width - 4, y: inset.midY - size.height / 2),
                  withAttributes: attrs)
    }
}
