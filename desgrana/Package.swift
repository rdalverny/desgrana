// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Desgrana",
    platforms: [.macOS(.v13)],
    targets: [
        // C shim: dr_wav.h (single-header WAV library, public domain). Test-only reference decoder.
        .target(
            name: "CWav",
            path: "Sources/CWav"
        ),
        // Shared core: WAV reader/writer, splitter, markers, session log, snap parser
        .target(
            name: "DesgranaCore",
            path: "Sources/Core"
        ),
        // CLI executable
        .executableTarget(
            name: "desgrana",
            dependencies: ["DesgranaCore"],
            path: "Sources/CLI"
        ),
        // C bridge for the Qt UI (Linux/Windows)
        .target(
            name: "DesgranaBridgeC",
            dependencies: ["DesgranaCore"],
            path: "Sources/BridgeC"
        ),
        // GUI executable (macOS only)
        .executableTarget(
            name: "DesgranaApp",
            dependencies: ["DesgranaCore"],
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
