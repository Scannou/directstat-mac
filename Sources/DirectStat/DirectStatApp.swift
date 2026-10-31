import AppKit
import SwiftUI

@main
struct DirectStatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DirectStat", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Whole Disk") { model.scanDisk() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Scan Home Folder") { model.scanHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Scan Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.result == nil)
            }
            CommandMenu("Item") {
                Button("Reveal in Finder") { if let s = model.selection { model.reveal(s) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selection == nil)
                Button("Copy Path") { if let s = model.selection { model.copyPath(s) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selection == nil)
                Button("Select Parent Folder") { model.selectParent() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.selection?.parentDir == nil)
                Divider()
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("+")
                    .disabled(!model.canZoomIn)
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(model.zoomRoot == nil)
                Divider()
                Button("Move to Trash…") { if let s = model.selection { model.delete(s, permanently: false) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!model.canDelete(model.selection))
                Button("Delete Permanently…") { if let s = model.selection { model.delete(s, permanently: true) } }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(!model.canDelete(model.selection))
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (swift run) instead of an .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        scheduleSnapshotIfRequested()
    }

    /// Dev aid: `--snapshot out.png [--snapshot-after secs]` saves the window
    /// as a PNG after a delay, then quits. Works without screen-recording permission.
    private func scheduleSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = args[i + 1]
        var delay = 8.0
        if let j = args.firstIndex(of: "--snapshot-after"), j + 1 < args.count, let d = Double(args[j + 1]) {
            delay = d
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
