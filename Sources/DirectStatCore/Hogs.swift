import Foundation

public enum HogSafety: Sendable {
    /// Caches and build output that tools re-create on their own.
    case safe
    /// Might hold something you want. Look before deleting.
    case review
}

/// A group of folders that are commonly safe or worth deleting.
public struct Hog: Identifiable, @unchecked Sendable {
    public var id: String { title }
    public let title: String
    public let detail: String
    public let safety: HogSafety
    public internal(set) var nodes: [DirNode]
    public var size: Int64 { nodes.reduce(0) { $0 + $1.size } }

    /// This hog without the folders inside `dir` (after `dir` was deleted).
    /// Nil when nothing is left.
    public func removing(under dir: DirNode) -> Hog? {
        var h = self
        h.nodes.removeAll { $0 === dir || dir.isAncestor(of: $0) }
        return h.nodes.isEmpty ? nil : h
    }
}

public enum HogFinder {
    struct Rule {
        let title: String
        let detail: String
        let safety: HogSafety
    }

    /// Known locations. "~" is the home folder.
    static let pathRules: [(String, Rule)] = [
        ("~/Library/Developer/Xcode/DerivedData", Rule(
            title: "Xcode DerivedData", detail: "Build cache. Xcode rebuilds it.", safety: .safe)),
        ("~/Library/Developer/Xcode/iOS DeviceSupport", Rule(
            title: "iOS DeviceSupport", detail: "Debug symbols per iOS version. Re-downloaded when you connect a device.", safety: .safe)),
        ("~/Library/Developer/Xcode/watchOS DeviceSupport", Rule(
            title: "watchOS DeviceSupport", detail: "Debug symbols per watchOS version.", safety: .safe)),
        ("~/Library/Developer/Xcode/Archives", Rule(
            title: "Xcode Archives", detail: "Old app builds. Keep any you may need to re-submit.", safety: .review)),
        ("~/Library/Developer/CoreSimulator/Devices", Rule(
            title: "iOS Simulator devices", detail: "Run `xcrun simctl delete unavailable` to drop old ones.", safety: .review)),
        ("~/Library/Developer/CoreSimulator/Caches", Rule(
            title: "Simulator caches", detail: "Re-created when needed.", safety: .safe)),
        ("/Library/Developer/CoreSimulator", Rule(
            title: "Simulator runtimes", detail: "Remove old ones in Xcode › Settings › Components.", safety: .review)),
        ("~/Library/Caches", Rule(
            title: "App caches", detail: "Apps re-create these. Quit apps before deleting.", safety: .safe)),
        ("~/Library/Logs", Rule(
            title: "Logs", detail: "Old log files.", safety: .safe)),
        ("~/.Trash", Rule(
            title: "Trash", detail: "Still uses space until you empty the Trash.", safety: .safe)),
        ("~/Library/Containers/com.docker.docker/Data/vms", Rule(
            title: "Docker disk image", detail: "Use `docker system prune` instead of deleting this file.", safety: .review)),
        ("~/Library/Application Support/MobileSync/Backup", Rule(
            title: "iPhone/iPad backups", detail: "Manage in Finder › your device › Manage Backups.", safety: .review)),
        ("~/Library/Messages/Attachments", Rule(
            title: "Messages attachments", detail: "Photos and files from chats.", safety: .review)),
        ("~/Downloads", Rule(
            title: "Downloads", detail: "Often holds old installers and archives.", safety: .review)),
        ("~/.npm", Rule(
            title: "npm cache", detail: "Run `npm cache clean --force`.", safety: .safe)),
        ("~/.cache", Rule(
            title: "Tool caches (~/.cache)", detail: "Caches from pip, Hugging Face, and other tools.", safety: .safe)),
        ("~/Library/pnpm/store", Rule(
            title: "pnpm store", detail: "Run `pnpm store prune`.", safety: .safe)),
        ("~/.gradle/caches", Rule(
            title: "Gradle caches", detail: "Re-downloaded on next build.", safety: .safe)),
        ("~/.m2/repository", Rule(
            title: "Maven repository", detail: "Re-downloaded on next build.", safety: .safe)),
        ("~/.cargo/registry", Rule(
            title: "Cargo registry", detail: "Re-downloaded on next build.", safety: .safe)),
        ("~/go/pkg/mod", Rule(
            title: "Go module cache", detail: "Run `go clean -modcache`.", safety: .safe)),
        ("/private/var/vm", Rule(
            title: "Swap and sleep image", detail: "Managed by macOS. A restart shrinks swap.", safety: .review)),
    ]

    static let nodeModules = Rule(
        title: "node_modules folders", detail: "JavaScript packages. Reinstall with npm/pnpm/yarn install.", safety: .safe)
    static let cacheDirTag = Rule(
        title: "Build caches", detail: "Folders marked as caches by build tools (CACHEDIR.TAG, e.g. Rust target/).", safety: .safe)
    static let venv = Rule(
        title: "Python virtual environments", detail: "Recreate with `python -m venv`.", safety: .review)
    static let pods = Rule(
        title: "CocoaPods folders", detail: "Run `pod install` to recreate.", safety: .safe)
    static let derivedData = Rule(
        title: "Xcode DerivedData", detail: "Build cache. Xcode rebuilds it.", safety: .safe)

    /// Strips the Data-volume prefix so "/System/Volumes/Data/Users/x" matches "/Users/x".
    static func normalize(_ path: String) -> String {
        Paths.withoutDataVolume(path)
    }

    static func matchByContents(_ d: DirNode) -> Rule? {
        switch d.name {
        case "node_modules": return nodeModules
        case "DerivedData": return derivedData
        default: break
        }
        for f in d.files {
            switch f.name {
            case "CACHEDIR.TAG": return cacheDirTag
            case "pyvenv.cfg": return venv
            case "Manifest.lock" where d.name == "Pods": return pods
            default: continue
            }
        }
        return nil
    }

    public static func find(in result: ScanResult, home: String = NSHomeDirectory(),
                            minSize: Int64 = 10_000_000) -> [Hog] {
        result.lock.lock(); defer { result.lock.unlock() }
        var byPath: [String: Rule] = [:]
        for (p, rule) in pathRules {
            let full = p.hasPrefix("~") ? home + p.dropFirst() : p
            byPath[full] = rule
        }

        var groups: [String: Hog] = [:]
        var order: [String] = []
        func add(_ rule: Rule, _ node: DirNode) {
            if groups[rule.title] == nil {
                groups[rule.title] = Hog(title: rule.title, detail: rule.detail, safety: rule.safety, nodes: [])
                order.append(rule.title)
            }
            groups[rule.title]!.nodes.append(node)
        }

        var stack: [(DirNode, String)] = [(result.root, normalize(result.root.name))]
        while let (node, path) = stack.popLast() {
            if node !== result.root {
                if let rule = byPath[path] ?? matchByContents(node) {
                    add(rule, node)
                    continue
                }
            }
            let base = path == "/" ? "/" : path + "/"
            for sub in node.subdirs where sub.size > 0 {
                stack.append((sub, base + sub.name))
            }
        }

        return order.compactMap { groups[$0] }
            .map { hog -> Hog in
                var h = hog
                h.nodes.sort(by: DirNode.bySize)
                return h
            }
            .filter { $0.size >= minSize }
            .sorted { $0.size > $1.size }
    }
}

public enum Queries {
    /// The biggest files anywhere under `root`, largest first.
    public static func largestFiles(in root: DirNode, limit: Int) -> [ItemRef] {
        guard limit > 0 else { return [] }
        var best: [(Int64, ItemRef)] = []
        var threshold: Int64 = 0
        var stack = [root]
        while let d = stack.popLast() {
            for (i, f) in d.files.enumerated() {
                if best.count >= limit && f.size <= threshold { break }
                best.append((f.size, .file(d, i)))
            }
            if best.count > limit * 4 {
                best.sort { $0.0 > $1.0 }
                best.removeLast(best.count - limit)
                threshold = best.last!.0
            }
            stack.append(contentsOf: d.subdirs)
        }
        best.sort { $0.0 > $1.0 }
        return best.prefix(limit).map(\.1)
    }
}
