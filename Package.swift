// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TickTrack",
    defaultLocalization: "ru",
    platforms: [.macOS(.v26)],
    targets: [
        // Логика учёта, правила списания, очередь отправки и клиент YouTrack. Без UI, покрыто тестами.
        .target(name: "TickTrackCore"),
        // Приложение в строке меню: AppKit-обвязка и SwiftUI-экраны.
        .executableTarget(
            name: "TickTrack",
            dependencies: ["TickTrackCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "TickTrackCoreTests", dependencies: ["TickTrackCore"]),
    ]
)
