// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipVault",
    platforms: [.macOS("15.4")],
    targets: [
        // Pure logic + SQLite storage + extension protocols. No AppKit / Vision / CoreML.
        .target(name: "ClipCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // Platform adapters: pasteboard, Vision, Core ML, Translation, hotkeys, downloads.
        .target(name: "ClipPlatform", dependencies: ["ClipCore"]),
        // App + CLI entry point.
        .executableTarget(name: "ClipVault", dependencies: ["ClipCore", "ClipPlatform"]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipPlatformTests", dependencies: ["ClipCore", "ClipPlatform"]),
    ]
)
