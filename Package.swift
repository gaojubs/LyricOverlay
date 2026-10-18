// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LyricOverlay",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "LyricOverlay",
            path: "Sources/LyricOverlay",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        )
    ]
)
