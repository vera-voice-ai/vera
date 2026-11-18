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
        .executableTarget(name: "VeraSensorPrototype", dependencies: ["SignalBus", "Sensors", "Scene"], path: "App")
    ]
)
