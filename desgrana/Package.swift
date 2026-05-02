// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Desgrana",
    platforms: [.macOS(.v13)],
    targets: [
        // C shim: dr_wav.h (single-header WAV library, public domain). Linux/Windows only.
        .target(
            name: "CWav",
            path: "Sources/CWav"
        ),
        // Shared core: markers, session log, snap parser
        .target(
            name: "DesgranaCore",
            path: "Sources/Core"
        ),
        // macOS splitter: AudioToolbox backend
        .target(
            name: "DesgranaCoreMac",
            dependencies: ["DesgranaCore"],
            path: "Sources/CoreMac",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        ),
        // Linux/Windows splitter: dr_wav backend
        .target(
            name: "DesgranaCoreLinux",
            dependencies: ["DesgranaCore", "CWav"],
            path: "Sources/CoreLinux"
        ),
        // CLI executable
        .executableTarget(
            name: "desgrana",
            dependencies: [
                "DesgranaCore",
                .target(name: "DesgranaCoreMac", condition: .when(platforms: [.macOS])),
                .target(name: "DesgranaCoreLinux", condition: .when(platforms: [.linux, .windows]))
            ],
            path: "Sources/CLI"
        ),
        // GUI executable (macOS only)
        .executableTarget(
            name: "DesgranaApp",
            dependencies: ["DesgranaCore", "DesgranaCoreMac"],
            path: "Sources/App",
            exclude: ["Desgrana.entitlements"]
        )
    ]
)
