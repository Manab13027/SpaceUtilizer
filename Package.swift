// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceUtilizer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SpaceUtilizer",
            path: "Sources/SpaceUtilizer"
        )
    ]
)
