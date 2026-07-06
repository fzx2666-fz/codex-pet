// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexPet",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexPet", targets: ["CodexStatusBar"]),
        .executable(name: "codex-status", targets: ["codex-status"])
    ],
    targets: [
        .executableTarget(
            name: "CodexStatusBar",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(name: "codex-status")
    ]
)
