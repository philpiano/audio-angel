// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "AudioAngel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AudioAngel", targets: ["AudioAngel"]),
    ],
    targets: [
        // Real-time mixing engine. Plain C: no allocation, no locks, no Swift runtime on the audio thread.
        .target(
            name: "RouterCore",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // SwiftUI app + Core Audio device/aggregate management.
        .executableTarget(
            name: "AudioAngel",
            dependencies: ["RouterCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Deterministic tests for the mixing engine (runs without any audio hardware).
        .executableTarget(
            name: "RouterCoreSelfTest",
            dependencies: ["RouterCore"]
        ),
    ]
)
