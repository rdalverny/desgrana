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
            name: "DesgranaCoreAudioToolbox",
            dependencies: ["DesgranaCore"],
            path: "Sources/CoreAudioToolbox",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        ),
        // Linux/Windows splitter: dr_wav backend
        .target(
            name: "DesgranaCoreWav",
            dependencies: ["DesgranaCore", "CWav"],
            path: "Sources/CoreWav"
        ),
        // CLI executable
        .executableTarget(
            name: "desgrana",
            dependencies: [
                "DesgranaCore",
                .target(name: "DesgranaCoreAudioToolbox", condition: .when(platforms: [.macOS])),
                .target(name: "DesgranaCoreWav", condition: .when(platforms: [.linux, .windows]))
            ],
            path: "Sources/CLI"
        ),
        // C bridge for the Qt UI (Linux/Windows)
        .target(
            name: "DesgranaBridgeC",
            dependencies: ["DesgranaCore", "DesgranaCoreWav"],
            path: "Sources/BridgeC"
        ),
        // GUI executable (macOS only)
        .executableTarget(
            name: "DesgranaApp",
            dependencies: ["DesgranaCore", "DesgranaCoreAudioToolbox"],
            path: "Sources/App",
            exclude: ["Desgrana.entitlements"]
        ),
        // Core unit tests
        .testTarget(
            name: "DesgranaCoreTests",
            dependencies: ["DesgranaCore"],
            path: "Tests/CoreTests"
        ),
        // Cross-checks WAVWriter output against the dr_wav reference writer/reader
        .testTarget(
            name: "DesgranaWriterTests",
            dependencies: ["DesgranaCore", "CWav"],
            path: "Tests/WriterTests"
        )
    ]
)
