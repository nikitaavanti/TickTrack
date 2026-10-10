// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TickTrack",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TickTrack", path: "Sources/TickTrack")
    ]
)
