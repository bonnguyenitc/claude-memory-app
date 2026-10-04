// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMemory",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .target(
            name: "MemoryCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .executableTarget(
            name: "ClaudeMemory",
            dependencies: ["MemoryCore"],
            resources: [.copy("Preview"), .copy("BrainMap")]),
        .testTarget(
            name: "MemoryCoreTests",
            dependencies: ["MemoryCore"]),
    ]
)
