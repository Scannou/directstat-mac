// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DirectStat",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DirectStat", targets: ["DirectStat"]),
        .executable(name: "directstat-cli", targets: ["directstat-cli"]),
    ],
    targets: [
        .target(name: "DirectStatCore"),
        .executableTarget(name: "DirectStat", dependencies: ["DirectStatCore"]),
        .executableTarget(name: "directstat-cli", dependencies: ["DirectStatCore"]),
        .testTarget(name: "DirectStatCoreTests", dependencies: ["DirectStatCore"]),
    ],
    swiftLanguageModes: [.v5]
)
