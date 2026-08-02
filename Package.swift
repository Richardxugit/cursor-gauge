// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CursorGauge",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CursorGaugeCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CursorGauge",
            dependencies: ["CursorGaugeCore"]
        ),
        .testTarget(
            name: "CursorGaugeCoreTests",
            dependencies: ["CursorGaugeCore"]
        ),
    ]
)
