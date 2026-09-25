// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Subtitler",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Pinned for WhisperKit's transitive use: 1.4+ calls Swift runtime functions
        // (swift_initBorrow) that shipping macOS versions don't have, so the app fails to launch.
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0"..<"1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Subtitler",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/Subtitler"
        ),
    ]
)
