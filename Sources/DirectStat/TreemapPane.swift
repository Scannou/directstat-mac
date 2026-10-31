import DirectStatCore
import SwiftUI

/// Renders the treemap off the main thread and keeps the latest image.
@MainActor
final class TreemapController: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var layout = TreemapLayout()
    private var generation = 0

    func request(root: DirNode?, result: ScanResult?, size: CGSize, scale: CGFloat) {
        generation += 1
        let gen = generation
        guard let root, let result, size.width >= 2, size.height >= 2 else {
            image = nil
            layout = TreemapLayout()
            return
        }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        Task.detached(priority: .userInitiated) {
            // Short pause so a live window resize renders once, not 60 times.
            try? await Task.sleep(for: .milliseconds(40))
            guard await self.isCurrent(gen) else { return }
            let (img, lay) = result.lock.withLock {
                TreemapRenderer.render(root: root, result: result, width: w, height: h, pixelScale: scale)
            }
            let cg = img.makeCGImage()
            await MainActor.run {
                guard gen == self.generation else { return }
                self.image = cg
                self.layout = lay
            }
        }
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation }

    func hitTest(_ p: CGPoint) -> ItemRef? {
        layout.hitTest(CGPoint(x: p.x * layout.pixelScale, y: p.y * layout.pixelScale))
    }

    func rect(for ref: ItemRef) -> CGRect? {
        guard let r = layout.rect(for: ref) else { return nil }
        let s = layout.pixelScale
        return CGRect(x: r.minX / s, y: r.minY / s, width: r.width / s, height: r.height / s)
    }
}

struct TreemapPane: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ctl = TreemapController()
    @Environment(\.displayScale) private var displayScale
    @State private var hover: ItemRef?
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                if let img = ctl.image {
                    Image(decorative: img, scale: ctl.layout.pixelScale)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if let sel = model.selection, let r = ctl.rect(for: sel) {
                    let w = max(r.width, 5), h = max(r.height, 5)
                    ZStack {
                        Rectangle().strokeBorder(Color.black.opacity(0.8), lineWidth: 4)
                        Rectangle().strokeBorder(Color.white, lineWidth: 2).padding(1)
                    }
                    .frame(width: w, height: h)
                    .offset(x: r.midX - w / 2, y: r.midY - h / 2)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                model.selection = ctl.hitTest(p)
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): hover = ctl.hitTest(p)
                case .ended: hover = nil
                }
            }
            .contextMenu {
                if let sel = model.selection {
                    Button("Reveal in Finder") { model.reveal(sel) }
                    Button("Zoom In") { model.zoomIn() }.disabled(!model.canZoomIn)
                    Button("Zoom Out") { model.zoomOut() }.disabled(model.zoomRoot == nil)
                    Divider()
                    Button("Move to Trash…") { model.delete(sel, permanently: false) }
                        .disabled(!model.canDelete(sel))
                }
            }
            .onAppear { size = geo.size; redraw() }
            .onChange(of: geo.size) { _, new in size = new; redraw() }
        }
        .onChange(of: model.revision) { redraw() }
        .onChange(of: model.zoomRoot.map(ObjectIdentifier.init)) { redraw() }
        .onChange(of: model.result.map(ObjectIdentifier.init)) { redraw() }
        .onChange(of: displayScale) { redraw() }
        .overlay(alignment: .bottomLeading) { hoverLabel }
        .overlay(alignment: .topLeading) { zoomBar }
    }

    private func redraw() {
        ctl.request(root: model.treemapRoot, result: model.result, size: size, scale: displayScale)
    }

    @ViewBuilder private var hoverLabel: some View {
        if let h = hover, h.size > 0 {
            HStack(spacing: 8) {
                Text(Fmt.bytes(h.size)).bold().monospacedDigit()
                Text(Paths.display(h.path)).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var zoomBar: some View {
        if let z = model.zoomRoot {
            HStack(spacing: 8) {
                Button { model.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                Button("Show All") { model.zoomRoot = nil }
                Text(Paths.display(z.path)).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
        }
    }
}
