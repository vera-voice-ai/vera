// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VeraSensorPrototype",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "VeraSensorPrototype", targets: ["VeraSensorPrototype"])],
    targets: [
        .target(name: "SignalBus", path: "SignalBus"),
        .target(name: "Sensors", dependencies: ["SignalBus"], path: "Sensors", resources: [.copy("Workers")]),
        .target(name: "Scene", dependencies: ["SignalBus"], path: "Scene"),
        .target(name: "Core", dependencies: ["SignalBus"], path: "Core"),
        .target(name: "HarnessKit", dependencies: ["Scene", "SignalBus"], path: "Harness/Kit"),
        .executableTarget(name: "Harness", dependencies: ["HarnessKit"], path: "Harness/CLI"),
        .executableTarget(name: "VeraSensorPrototype", dependencies: ["SignalBus", "Sensors", "Scene", "Core"], path: "App"),
        .testTarget(name: "SceneTests", dependencies: ["Scene", "SignalBus", "Sensors", "Core", "HarnessKit"], path: "Tests/SceneTests")
    ]
)
