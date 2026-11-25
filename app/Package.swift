// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Vera03",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .executable(name: "Vera", targets: ["Vera"]),
        // The phone app (phone/) links this: what the iPhone sensor and Vera say to each other.
        .library(name: "PhoneWire", targets: ["PhoneWire"]),
        // Vera's UI kit: colours, type scale, the shared parts (module contour, cards, pills) and the kit window — Mac and phone.
        .library(name: "VeraKit", targets: ["VeraKit"]),
        // Vera's voice without Python: Silero v5 (ru) as ONNX plus its text side in Swift — the phone speaks with it.
        .library(name: "SileroVoice", targets: ["SileroVoice"]),
        // Vera's music library, the same on the Mac and the phone (tracks, «Моё любимое», artists, albums, queue).
        .library(name: "VeraMusic", targets: ["VeraMusic"]),
        // Listening mechanics shared by the Mac and the phone: the key word «Вера», the background transcript.
        .library(name: "VeraListen", targets: ["VeraListen"]),
    ],
    targets: [
        // No UI: where Hermes is, the gateway attach and WebSocket client, the vera-pulse journal, the lock check.
        .target(name: "HermesBridge", path: "Sources/HermesBridge"),
        // Vera's ears: the sherpa-onnx C library is loaded from the box at run time (no link-time dependency).
        .target(name: "CSherpa", path: "Sources/CSherpa", exclude: ["vendor"], publicHeadersPath: "include"),
        .target(name: "VeraListen", path: "Sources/VeraListen"),
        .target(name: "VeraEars", dependencies: ["CSherpa", "VeraListen", "SileroVoice"], path: "Sources/VeraEars"),
        // The iPhone sensor: the wire format (shared with the phone app) and Vera's door for it (pairing, WebSocket).
        .target(name: "PhoneWire", path: "Sources/PhoneWire"),
        .target(name: "VeraKit", path: "Sources/VeraKit"),
        // onnxruntime's C API, nothing linked: the Mac loads the box's dylib, the phone hands over its framework's API.
        .target(name: "COnnx", path: "Sources/COnnx", exclude: ["vendor"], publicHeadersPath: "include"),
        .target(name: "SileroVoice", dependencies: ["COnnx"], path: "Sources/SileroVoice"),
        .target(name: "VeraMusic", path: "Sources/VeraMusic"),
        .target(name: "PhoneGate", dependencies: ["PhoneWire"], path: "Sources/PhoneGate"),
        .executableTarget(name: "Vera", dependencies: ["HermesBridge", "VeraEars", "PhoneWire", "PhoneGate", "VeraKit", "SileroVoice", "VeraMusic"], path: "Sources/Vera"),
        .testTarget(name: "HermesBridgeTests", dependencies: ["HermesBridge"], path: "Tests/HermesBridgeTests"),
        .testTarget(name: "VeraEarsTests", dependencies: ["VeraEars", "VeraListen"], path: "Tests/VeraEarsTests"),
        .testTarget(name: "PhoneGateTests", dependencies: ["PhoneGate", "PhoneWire"], path: "Tests/PhoneGateTests"),
        .testTarget(name: "VeraMusicTests", dependencies: ["VeraMusic"], path: "Tests/VeraMusicTests"),
        .testTarget(name: "SileroVoiceTests", dependencies: ["SileroVoice"], path: "Tests/SileroVoiceTests",
                    resources: [.copy("golden.json")])
    ]
)
