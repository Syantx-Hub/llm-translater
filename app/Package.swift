// swift-tools-version: 5.10
import Foundation
import PackageDescription

// With only the Command Line Tools installed, the Swift Testing macro plugin sits in a
// subfolder the compiler doesn't search; point it there. Xcode installs need nothing.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugins)
    ? [.unsafeFlags(["-plugin-path", testingPlugins])]
    : []

let package = Package(
    name: "Subtitler",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Pinned for WhisperKit's transitive use: 1.4+ calls Swift runtime functions
        // (swift_initBorrow) that shipping macOS versions don't have, so the app fails to launch.
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0"..<"1.4.0"),
        // Runs the Silero voice-activity model (MIT, bundled in Resources).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.19.2"),
    ],
    targets: [
        // Prebuilt llama.cpp with Metal, used to run GGUF translation models natively.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11190/llama-b11190-xcframework.zip",
            checksum: "03de57d3597ff23de0f50abc22748769a8c28c67b0a9754718a9e5231a9c9cf6"
        ),
        .executableTarget(
            name: "Subtitler",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                "llama",
            ],
            path: "Sources/Subtitler",
            resources: [.copy("Resources/silero_vad.onnx")],
            linkerSettings: [
                // llama.framework ships in Subtitler.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "SubtitlerTests",
            dependencies: ["Subtitler"],
            path: "Tests/SubtitlerTests",
            swiftSettings: testSwiftSettings
        ),
    ]
)
