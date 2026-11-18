// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VeraLauncher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "vera-launcher", targets: ["VeraLauncher"])],
    targets: [
        .executableTarget(name: "VeraLauncher", path: "Sources/VeraLauncher")
    ]
)
